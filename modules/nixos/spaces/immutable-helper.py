# One request of a space guest's root (./host.nix, immutableHelper): on
# stdin (an accepted AF_UNIX connection), one byte b"1" (set) or b"0"
# (clear) with a descriptor (SCM_RIGHTS) of the file or directory. In its
# own user namespace the guest lacks CAP_LINUX_IMMUTABLE (the kernel wants
# it in the initial namespace), this service has it.
#
# Done only if the peer is the guest's root (SO_PEERCRED: SPACE_UID_BASE)
# and the descriptor's file is a regular file or directory of its root,
# on the file system of the guest's root tree (SPACE_ROOT), below the one
# directory of the guest the flags are for (SPACE_IMMUTABLE_DIR, hermes'
# locked home): nothing of this host the guest could have been handed,
# and nothing elsewhere in its tree. Where the file is: that directory
# opened here, from SPACE_ROOT one component at a time without following
# a link (the guest's links and mounts steer nothing), and the
# descriptor's inode one of its entries (a regular file with no other
# hard link). fstat sees an idmapped mount's owners, so the guest's files are
# the base's; the store, bound in read-only, refuses the ioctl (EROFS:
# the descriptor's mount). Replies b"ok" or b"error: ...".
import array
import fcntl
import os
import socket
import stat
import struct
import sys

FS_IOC_GETFLAGS = 0x80086601
FS_IOC_SETFLAGS = 0x40086602
FS_IMMUTABLE_FL = 0x10

base = int(os.environ["SPACE_UID_BASE"])
root_dev = os.stat(os.environ["SPACE_ROOT"]).st_dev
name = os.environ["SPACE_NAME"]
conn = socket.socket(fileno=0)


def reply(msg):
    try:
        conn.sendall(msg.encode())
    except OSError:
        pass
    print(f"space-immutable {name}: {msg}", file=sys.stderr)


def in_dir(st):
    """Whether (dev, ino) of `st` is an entry directly in SPACE_IMMUTABLE_DIR."""
    fd = os.open(os.environ["SPACE_ROOT"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for part in os.environ["SPACE_IMMUTABLE_DIR"].strip("/").split("/"):
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = nxt
        if os.fstat(fd).st_dev != st.st_dev:
            return False
        for entry in os.listdir(fd):
            e = os.stat(entry, dir_fd=fd, follow_symlinks=False)
            if (e.st_dev, e.st_ino) == (st.st_dev, st.st_ino):
                return True
        return False
    finally:
        os.close(fd)


def main():
    pid, uid, gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    if uid != base:
        return reply(f"error: peer uid {uid} is not the guest's root")
    fds = array.array("i")
    msg, anc, _, _ = conn.recvmsg(1, socket.CMSG_SPACE(4 * fds.itemsize))
    for level, kind, data in anc:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            fds.frombytes(data[: len(data) - len(data) % fds.itemsize])
    try:
        if msg not in (b"0", b"1") or len(fds) != 1:
            return reply("error: expected b'0' or b'1' and one descriptor")
        fd = fds[0]
        st = os.fstat(fd)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            return reply("error: neither a file nor a directory")
        if st.st_dev != root_dev or st.st_uid != base:
            return reply("error: not a file of the guest's root in its root tree")
        if stat.S_ISREG(st.st_mode) and st.st_nlink != 1:
            return reply("error: a file with other hard links")
        if not in_dir(st):
            return reply(f"error: not an entry of {os.environ['SPACE_IMMUTABLE_DIR']}")
        flags = struct.unpack("i", fcntl.ioctl(fd, FS_IOC_GETFLAGS, struct.pack("i", 0)))[0]
        new = flags | FS_IMMUTABLE_FL if msg == b"1" else flags & ~FS_IMMUTABLE_FL
        fcntl.ioctl(fd, FS_IOC_SETFLAGS, struct.pack("i", new))
        if msg == b"1":
            # The guest could have moved or linked the inode between the
            # checks and the ioctl. Now immutable, it can be neither
            # renamed nor linked any more: checked again on the same fd,
            # this result holds. On a mismatch, take the flag off again.
            # Any error in the re-check (a swapped path component makes
            # in_dir raise) also takes the flag off. If that clear itself
            # fails, the flag stays on the guest's own file; host root can
            # clear it.
            try:
                st = os.fstat(fd)
                ok = not (stat.S_ISREG(st.st_mode) and st.st_nlink != 1) and in_dir(st)
            except OSError:
                ok = False
            if not ok:
                fcntl.ioctl(fd, FS_IOC_SETFLAGS, struct.pack("i", flags & ~FS_IMMUTABLE_FL))
                return reply("error: moved or linked while being set, flag cleared")
        reply("ok")
    except OSError as e:
        reply(f"error: {e}")
    finally:
        for fd in fds:
            os.close(fd)


main()
