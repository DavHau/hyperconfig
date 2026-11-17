"""space-usb: one USB device node into (or out of) a space container.

./usb-ports.nix has the why. Runs as host root:

  space-usb <config.json> add|remove <space>:<dev>
  space-usb <config.json> replay <space>
  space-usb <config.json> net <space>:<ifindex>
  space-usb <config.json> revoke <space>

<dev> is a kernel name (sdb1, ttyUSB0, hidraw3) or usb-<sysfs name>
(usb-2-2.1) for the raw usb_device node. The guest's root must not be able
to turn any step into a write on something else of the host's, so:

- the container's cgroup allows exactly the major:minor of the devices
  handed over now (`systemctl set-property --runtime`, the full list each
  time: the static one from the unit plus these), revoked on remove, so a
  hard link the guest kept opens nothing once the number goes to another
  device. On remove the device's state becomes `<dev>.revoking` (out of
  the list) and goes only once a list without it is set (retried; a
  failure starts space-usb-revoke@<space>, which retries with backoff
  until it is set), so no record is lost while the cgroup may still
  allow the number;
- the node is made in a fresh directory of host root's (mode 0700, owner
  unmapped in the guest), chowned there without following anything and
  renamed into place; every directory on the way is opened one component
  at a time with O_NOFOLLOW, so a symlink the guest planted makes this
  fail instead of writing elsewhere;
- the mount namespace is entered through a pidfd of the container's leader,
  checked to be the nspawn child (pid 1 of the container's pid namespace,
  parent the unit's MainPID, in the unit's cgroup) while the pidfd is held.
"""

import ctypes
import fcntl
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time
from typing import NoReturn

NODE = re.compile(r"[A-Za-z0-9_:.-]+(/[A-Za-z0-9_:.-]+)*")
DEV = re.compile(r"(usb-)?[A-Za-z0-9][A-Za-z0-9.:-]*")
STATE = "/run/space-usb"
AT_EMPTY_PATH = 0x1000
TMPFS_MAGIC = 0x01021994
libc = ctypes.CDLL(None, use_errno=True)


def fs_type(fd):
    buf = ctypes.create_string_buffer(120)  # struct statfs; f_type first
    if libc.fstatfs(fd, buf) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return ctypes.c_long.from_buffer(buf).value


def log(msg):
    print(f"space-usb: {msg}", file=sys.stderr, flush=True)


def die(msg) -> NoReturn:
    log(msg)
    sys.exit(1)


def on_port(cfg, real):
    return any(f"/{port}/" in real + "/" for port in cfg["ports"])


def device(cfg, dev):
    """The device's node name, numbers and type, if it is on one of the space's ports."""
    if dev.startswith("usb-"):
        link = "/sys/bus/usb/devices/" + dev[4:]
    else:
        # the kernel name in its class (the udev rule: any node on the port)
        link = next((p for c in sorted(os.listdir("/sys/class")) if os.path.exists((p := f"/sys/class/{c}/{dev}") + "/dev")), None)
    if link is None or not os.path.exists(link):
        return None
    real = os.path.realpath(link)
    if not on_port(cfg, real):
        die(f"{dev} ({real}) is on none of the space's ports")
    try:
        with open(f"{real}/dev") as f:
            major, minor = (int(x) for x in f.read().strip().split(":"))
        with open(f"{real}/uevent") as f:
            name = next((line.strip()[8:] for line in f if line.startswith("DEVNAME=")), None)
    except FileNotFoundError:
        return None
    if name is None or not NODE.fullmatch(name) or any(c in (".", "..") or c.startswith(".") for c in name.split("/")):
        die(f"{dev}: unexpected node name {name!r}")
    block = os.path.basename(os.path.realpath(f"{real}/subsystem")) == "block"
    return {"node": name, "major": major, "minor": minor, "block": block}


def unit(space):
    return f"container@{space}.service"


def leader(space):
    """A pidfd of the container's pid 1, or None if the container isn't running."""
    def show(*args):
        r = subprocess.run(["systemctl", "show", "--value", *args], capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""
    r = subprocess.run(["machinectl", "show", space, "-p", "Leader", "--value"], capture_output=True, text=True)
    pid = int(r.stdout.strip() or 0) if r.returncode == 0 else 0
    if pid <= 0:
        return None
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return None
    main = show("-p", "MainPID", unit(space))
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            cgroup = f.read()
        with open(f"/proc/{pid}/status") as f:
            status = dict(line.rstrip("\n").split(":\t", 1) for line in f if ":\t" in line)
    except FileNotFoundError:
        os.close(fd)
        return None
    ok = (
        f"0::/machine.slice/{unit(space)}/" in cgroup
        and status.get("PPid") == main
        and status.get("NSpid", "").split() == [str(pid), "1"]
    )
    try:
        # still the process the checks above read (pid not reused meanwhile)
        signal.pidfd_send_signal(fd, 0)
    except ProcessLookupError:
        ok = False
    if not ok:
        os.close(fd)
        log(f"{space}: leader {pid} is not the container's pid 1 (main {main}), not entering it")
        return None
    return fd, pid


def walk(path, create, owner=None):
    """An fd of the directory /<path> in the current mount namespace, no symlink followed.

    Every component is on the tmpfs nspawn mounted at /dev, so a mount the
    guest put there (its home, say) is refused.
    """
    fd = os.open("/", os.O_DIRECTORY | os.O_RDONLY)
    devfs = None
    for comp in path.split("/"):
        made = False
        if create:
            try:
                os.mkdir(comp, 0o755, dir_fd=fd)
                made = True
            except FileExistsError:
                pass
        try:
            nfd = os.open(comp, os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
        finally:
            os.close(fd)
        fd = nfd
        if made and owner is not None:
            # the guest's root's, as the rest of its /dev (it may tidy up)
            os.fchown(fd, owner, owner)
        st = os.fstat(fd)
        devfs = devfs or st.st_dev
        if st.st_dev != devfs or fs_type(fd) != TMPFS_MAGIC:
            os.close(fd)
            raise OSError(f"/{path}: {comp} is not on the guest's /dev tmpfs")
    return fd


def guest_add(d, base, uid):
    parent, name = os.path.split("dev/" + d["node"])
    dfd = walk(parent, create=True, owner=base)
    tmp = f".space-usb-{secrets.token_hex(8)}"
    os.mkdir(tmp, 0o700, dir_fd=dfd)
    tfd = os.open(tmp, os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    try:
        if os.fstat(tfd).st_uid != 0:
            raise OSError(f"{tmp}: not ours")
        kind = stat.S_IFBLK if d["block"] else stat.S_IFCHR
        rdev = os.makedev(d["major"], d["minor"])
        os.mknod(name, 0o660 | kind, rdev, dir_fd=tfd)
        nfd = os.open(name, os.O_PATH | os.O_NOFOLLOW, dir_fd=tfd)
        try:
            st = os.fstat(nfd)
            if stat.S_IFMT(st.st_mode) != kind or st.st_rdev != rdev or st.st_dev != os.fstat(dfd).st_dev:
                raise OSError(f"{name}: not the node just made")
            # the space's user's (libusb, hidraw, serial without root)
            if libc.fchownat(nfd, b"", base + uid, base + uid, AT_EMPTY_PATH) != 0:
                e = ctypes.get_errno()
                raise OSError(e, os.strerror(e))
        finally:
            os.close(nfd)
        os.rename(name, name, src_dir_fd=tfd, dst_dir_fd=dfd)
    finally:
        for leftover in os.listdir(tfd):
            os.unlink(leftover, dir_fd=tfd)
        os.close(tfd)
        try:
            os.rmdir(tmp, dir_fd=dfd)
        finally:
            os.close(dfd)


def guest_remove(d):
    parent, name = os.path.split("dev/" + d["node"])
    dfd = walk(parent, create=False)
    try:
        st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        kind = stat.S_IFBLK if d["block"] else stat.S_IFCHR
        if stat.S_IFMT(st.st_mode) == kind and st.st_rdev == os.makedev(d["major"], d["minor"]):
            os.unlink(name, dir_fd=dfd)
    finally:
        os.close(dfd)


def in_guest(leader_, fn, *args):
    """Run fn in the container's mount namespace (a child process; this one stays on the host)."""
    pid = os.fork()
    if pid == 0:
        try:
            os.setns(leader_[0], os.CLONE_NEWNS)
            os.umask(0)
            fn(*args)
            os._exit(0)
        except BaseException as e:  # noqa: B036 report anything, never return into the parent's code
            log(f"in the guest: {e!r}")
            os._exit(1)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 0


def net_ifaces(cfg):
    """{ifindex: name} of this netns' interfaces on the space's ports."""
    out = {}
    for name in os.listdir("/sys/class/net"):
        real = os.path.realpath(f"/sys/class/net/{name}")
        if on_port(cfg, real):
            with open(f"{real}/ifindex") as f:
                out[int(f.read())] = name
    return out


def move_net(cfg, space, ifindex, lead):
    """Interface <ifindex> of the host into the guest's netns, as usb<N>.

    The guest's networkd takes it from there (./usb-ports.nix: DHCP, no
    routes or DNS from it). Waits for udev to finish with it (its rename).
    """
    for _ in range(100):
        if os.path.exists(f"/run/udev/data/n{ifindex}"):
            break
        time.sleep(0.1)
    name = net_ifaces(cfg).get(ifindex)
    if name is None:
        return
    nsfd = os.open(f"/proc/{lead[1]}/ns/net", os.O_RDONLY)
    try:
        # still the leader checked: the fd is its netns
        signal.pidfd_send_signal(lead[0], 0)
        r = subprocess.run(["ip", "link", "set", "dev", name, "netns", f"/proc/self/fd/{nsfd}", "name", "usb%d"], pass_fds=[nsfd])
    finally:
        os.close(nsfd)
    if r.returncode != 0:
        if ifindex in net_ifaces(cfg):
            die(f"{name}: not moved into {space}")
        return  # moved meanwhile (the replay and udev both at it)
    log(f"{name} (ifindex {ifindex}) into {space}")


def states(space):
    """{dev: state} of the devices handed over now (a state file each)."""
    d = f"{STATE}/{space}"
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if f.endswith((".tmp", ".revoking")):
            continue
        try:
            with open(f"{d}/{f}") as fh:
                out[f] = json.load(fh)
        except ValueError:
            log(f"{d}/{f}: unreadable, ignored")
    return out


def set_allow(cfg, space, retry_unit=True):
    """The container's DeviceAllow: the unit's own list plus the devices handed over now.

    Retried: a revocation must not be skipped because systemd was busy.
    Once set, the revocations pending before are done (their files go).
    If it still fails with revocations pending, space-usb-revoke@<space>
    keeps retrying (Restart=on-failure, backoff) until one is set.
    """
    d = f"{STATE}/{space}"
    pending = [f for f in os.listdir(d) if f.endswith(".revoking")] if os.path.isdir(d) else []
    extra = [f"/dev/{'block' if s['block'] else 'char'}/{s['major']}:{s['minor']} rw" for s in states(space).values()]
    args = ["DeviceAllow="] + [f"DeviceAllow={e}" for e in cfg["deviceAllow"] + extra]
    for attempt in range(10):
        r = subprocess.run(["systemctl", "set-property", "--runtime", unit(space), *args])
        if r.returncode == 0:
            for f in pending:
                os.unlink(f"{d}/{f}")
            return
        log(f"{unit(space)}: DeviceAllow not set (try {attempt + 1})")
        time.sleep(0.5)
    if retry_unit and pending:
        subprocess.run(["systemctl", "start", "--no-block", f"space-usb-revoke@{space}.service"], check=False)
    raise subprocess.CalledProcessError(r.returncode, "systemctl set-property")


def lock(space):
    os.makedirs(f"{STATE}/{space}", mode=0o700, exist_ok=True)
    fd = os.open(f"{STATE}/{space}.lock", os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def main():
    config, action, arg = sys.argv[1:4]
    with open(config) as f:
        spaces = json.load(f)
    if action == "revoke":
        space = arg
        if space not in spaces:
            die(f"unknown space {space}")
        lock(space)
        d = f"{STATE}/{space}"
        if os.path.isdir(d) and any(f.endswith(".revoking") for f in os.listdir(d)):
            set_allow(spaces[space], space, retry_unit=False)  # fails: the unit restarts
            log(f"{space}: pending revocations done")
        return
    if action == "replay":
        space = arg
        if space not in spaces:
            die(f"unknown space {space}")
        lfd = lock(space)
        # Once per run of the container: a start job on the running one
        # (it pulls this in again) has nothing to replay.
        inv = subprocess.run(["systemctl", "show", "--value", "-p", "InvocationID", unit(space)], capture_output=True, text=True).stdout.strip()
        seen = f"{STATE}/{space}.invocation"
        if inv and os.path.exists(seen) and open(seen).read() == inv:
            log(f"{space}: already replayed for this run ({inv})")
            return
        # A new container: its /dev is a new tmpfs, none of the old nodes
        # (nor links to them: links don't leave a filesystem, and the guest
        # can't make device nodes) is left. The list back to the unit's
        # own if a runtime one is set (a hand-over by hand included), then
        # forget them; the plugged devices' units add them again.
        for f in os.listdir(f"{STATE}/{space}"):
            if not f.endswith(".revoking"):
                os.replace(f"{STATE}/{space}/{f}", f"{STATE}/{space}/{f.removesuffix('.tmp')}.revoking")
        if os.path.exists(f"/run/systemd/system.control/{unit(space)}.d/50-DeviceAllow.conf"):
            set_allow(spaces[space], space)
        else:
            for f in os.listdir(f"{STATE}/{space}"):
                os.unlink(f"{STATE}/{space}/{f}")
        os.close(lfd)
        # its network interfaces: those on the ports back in the host's netns
        lead = leader(space)
        if lead is not None:
            for ifindex in net_ifaces(spaces[space]):
                try:
                    move_net(spaces[space], space, ifindex, lead)
                except (OSError, subprocess.CalledProcessError) as e:
                    log(f"ifindex {ifindex}: {e}")
        # loaded instances only: the devices plugged now (none: no-op)
        subprocess.run(["systemctl", "restart", "--no-block", f"space-usb@{space}:*"], check=False)
        if inv:
            with open(seen + ".tmp", "w") as f:
                f.write(inv)
            os.rename(seen + ".tmp", seen)
        return
    space, _, dev = arg.partition(":")
    if space not in spaces or not DEV.fullmatch(dev):
        die(f"bad instance {arg!r}")
    cfg = spaces[space]
    if action == "net":
        lead = leader(space)
        if lead is None:
            log(f"{space} not running (its start moves this)")
            return
        move_net(cfg, space, int(dev), lead)
        return
    lock(space)
    state = f"{STATE}/{space}/{dev}"
    if action == "remove":
        if not os.path.exists(state):
            if os.path.exists(state + ".revoking"):
                set_allow(cfg, space)  # an earlier revocation that failed
            return
        try:
            with open(state) as f:
                d = json.load(f)
        except ValueError:
            d = None
        # revoke first: a node or link the guest kept opens nothing. The
        # record stays (as .revoking, out of the list) until a list
        # without it is set: a failure here fails the unit and starts
        # space-usb-revoke@<space>, which retries until it is set.
        os.replace(state, state + ".revoking")
        try:
            set_allow(cfg, space)
        finally:
            lead = leader(space) if d is not None else None
            if lead is not None:
                in_guest(lead, guest_remove, d)
        return
    if action != "add":
        die(f"bad action {action!r}")
    d = device(cfg, dev)
    if d is None:
        return
    lead = leader(space)
    if lead is None:
        log(f"{space} not running (its start replays this)")
        return
    with open(state + ".tmp", "w") as f:
        json.dump(d, f)
    os.rename(state + ".tmp", state)
    set_allow(cfg, space)
    if not in_guest(lead, guest_add, d, cfg["base"], cfg["uid"]):
        os.replace(state, state + ".revoking")
        set_allow(cfg, space)
        die(f"/dev/{d['node']} not made in {space}")
    log(f"/dev/{d['node']} ({'b' if d['block'] else 'c'} {d['major']}:{d['minor']}) into {space}")


main()
