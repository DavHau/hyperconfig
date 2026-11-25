# Slot storage (../../modules/container-slots-storage) on a test pool:
# alice's agent slot starts on a root that already holds data, so it runs
# on its directory without scratch binds; slot-storage-migrate refuses a
# root above its quota, then moves it onto its datasets: the old /var/tmp
# contents land in the scratch dataset, the guest sees /scratch, /var/tmp,
# /var/lib/docker and an extra /home/agent/.cache with the declared owners
# and can write there as that user, the root quota stops writes in the
# root only. --finalize drops the old tree; `slot reset --hard` empties
# both datasets and the slot comes back with its binds. A fresh slot gets
# its datasets at first start. A data path (its own dataset, quota and
# reservation) that already holds data in the root (setgid dir, ACL and
# default ACL, non-root guest owners) is migrated at the next start: a
# failing copy blocks the start and leaves the root as it was; then the
# guest sees the same content and ACLs and can write; a further start
# copies nothing. The guest module (nixosModules.slot) on a
# plain VM: tool defaults, a cache user's ~/.cache bound from /scratch, a
# non-empty one left alone.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  common = import ../slots/common.nix { inherit pkgs; };
  rootQuota = "256M";
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-container-slots-storage";
  globalTimeout = 1200;

  nodes.host =
    { config, ... }:
    {
      imports = [
        common.agentsStub
        common.slotHost
        self.nixosModules.exposure
        self.nixosModules.slots
      ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.vlans = [ 1 ];
      virtualisation.emptyDiskImages = [
        {
          size = 2048;
          driveConfig.deviceExtraOpts.serial = "tpool";
        }
      ];
      networking.hostId = "8425e349";

      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      systemd.network.networks."40-br0".address = [ "192.0.2.2/24" ];
      services.container-slots = {
        enable = true;
        uplink = "eth1";
        uplinkMac = common.uplinkMacOf config;
        lanIPv4 = "192.0.2.0/24";
        ipv6Prefix = "2001:db8:1:2";
        deployKeys = [ common.adminKey ];
        storage = {
          enable = true;
          rootParent = "tpool/slots";
          scratchParent = "tpool/nobackup/slots";
          dataParent = "tpool/slot-data";
        };
        slots.alice.storage = {
          enable = true;
          inherit rootQuota;
          scratchQuota = "768M";
          scratchPaths."/home/agent/.cache" = {
            uid = 1000;
            gid = 100;
            mode = "0700";
          };
        };
        slots.fresh = {
          id = 5;
          mode = "isolated";
          autoStart = false;
          storage = {
            enable = true;
            dataPaths."/var/lib/db" = {
              quota = "64M";
              uid = 1000;
              gid = 992;
              mode = "2770";
            };
          };
        };
      };

      services.hyperhermes = {
        exposure.enable = true;
        agents.alice = {
          uid = 1000;
          slot = {
            enable = true;
            id = 4;
            deployKey = common.sshKeys.alice.pub;
          };
        };
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
      environment.systemPackages = config.services.hyperhermes.extraPackages;
    };

  nodes.guest = {
    imports = [ self.nixosModules.slot ];
    # a VM stands in for the slot here (the agent slots above run the
    # bootstrap, which is this module too)
    boot.isNspawnContainer = lib.mkForce false;
    # stands in for the host's bind of the slot's scratch dataset
    virtualisation.fileSystems."/scratch" = {
      fsType = "tmpfs";
      options = [ "mode=1777" ];
    };
    users.users.agent = {
      isNormalUser = true;
      uid = 1000;
    };
    users.users.other = {
      isNormalUser = true;
      uid = 1001;
    };
    # a cache that predates the module: never hidden
    systemd.tmpfiles.rules = [
      "d /home/other/.cache 0700 other users -"
      "f /home/other/.cache/keep 0600 other users - kept"
    ];
    containerSlot.cacheUsers = [
      "agent"
      "other"
    ];
  };

  testScript = ''
    import shlex

    def in_slot(name, cmd):
        leader = host.succeed(f"machinectl show {name} -p Leader --value").strip()
        return host.succeed(f"${pkgs.util-linux}/bin/nsenter -t {leader} -a {cmd}")

    def in_slot_fail(name, cmd):
        leader = host.succeed(f"machinectl show {name} -p Leader --value").strip()
        host.fail(f"${pkgs.util-linux}/bin/nsenter -t {leader} -a {cmd}")

    def guest_mount_source(name, path):
        leader = host.succeed(f"machinectl show {name} -p Leader --value").strip()
        return host.succeed(f"findmnt -rn -o SOURCE --task {leader} --mountpoint {path}").strip()

    stat = "${pkgs.coreutils}/bin/stat -c '%u %g %a' "
    as_agent = "${pkgs.util-linux}/bin/setpriv --reuid=1000 --regid=100 --clear-groups "

    start_all()
    host.wait_for_unit("multi-user.target")

    with subtest("a pool like som's: snapshotted root, unsnapshotted nobackup"):
        host.succeed("zpool create -O mountpoint=none -O acltype=posix -O xattr=sa -O com.sun:auto-snapshot=true tpool /dev/disk/by-id/virtio-tpool")
        host.succeed("zfs create -o com.sun:auto-snapshot=false tpool/nobackup")

    with subtest("a root that holds data stays a directory, without binds"):
        root = "/var/lib/nixos-containers/alice"
        # owned by host root, as nspawn's idmapped root keeps guest ids
        host.succeed(
            f"mkdir -p {root}/var/tmp {root}/srv",
            f"echo old > {root}/var/tmp/old-file",
            f"head -c 300M /dev/urandom > {root}/srv/big",
        )
        host.succeed("runuser -u alice -- slot start")
        host.wait_until_succeeds("machinectl show alice -p Leader --value", timeout=90)
        assert in_slot("alice", "${pkgs.coreutils}/bin/cat /var/tmp/old-file").strip() == "old"
        host.fail(f"findmnt --mountpoint {root}")
        host.succeed("journalctl -u container-slot-storage@alice | grep -q 'migrate it with: slot-storage-migrate alice'")
        host.fail("test -e /run/container-slots/alice/storage.env")

    with subtest("migration refuses a root above its quota and lists the culprit"):
        out = host.fail("slot-storage-migrate alice --dry-run 2>&1")
        assert "does not fit rootQuota ${rootQuota}" in out, out
        assert f"{root}/srv" in out, out
        host.succeed(f"rm {root}/srv/big")
        out = host.succeed("slot-storage-migrate alice --dry-run 2>&1")
        assert "dry run" in out, out
        host.fail("zfs list tpool/slots/alice")

    with subtest("migration moves the slot onto its datasets"):
        out = host.succeed("slot-storage-migrate alice 2>&1")
        print(out)
        assert "the slot runs with its scratch binds" in out, out
        assert host.succeed(f"findmnt -rn -o SOURCE --mountpoint {root}").strip() == "tpool/slots/alice"
        assert host.succeed("findmnt -rn -o SOURCE --mountpoint /var/lib/slot-scratch/alice").strip() == "tpool/nobackup/slots/alice"
        assert host.succeed("zfs get -H -o value refquota tpool/slots/alice").strip() == "${rootQuota}"
        host.succeed("test -d /var/lib/nixos-containers/.premigrate-alice")
        host.fail("test -e /var/lib/nixos-containers/.premigrate-alice/var/tmp/old-file")
        host.succeed("grep -q old /var/lib/slot-scratch/alice/var-tmp/old-file")
        assert in_slot("alice", "${pkgs.coreutils}/bin/cat /var/tmp/old-file").strip() == "old"
        assert guest_mount_source("alice", "/var/tmp") == "tpool/nobackup/slots/alice[/var-tmp]"

    with subtest("the guest sees the declared owners and can write as them"):
        assert in_slot("alice", stat + "/scratch").strip() == "0 0 1777"
        assert in_slot("alice", stat + "/var/lib/docker").strip() == "0 0 710"
        assert in_slot("alice", stat + "/root/.cache").strip() == "0 0 700"
        assert in_slot("alice", stat + "/home/agent/.cache").strip() == "1000 100 700"
        in_slot("alice", as_agent + "${pkgs.coreutils}/bin/touch /scratch/mine /home/agent/.cache/mine")
        in_slot_fail("alice", as_agent + "${pkgs.coreutils}/bin/touch /var/lib/docker/not-mine")
        # idmapped: guest ids on disk, as in the root
        assert host.succeed("stat -c %u /var/lib/slot-scratch/alice/scratch/mine").strip() == "1000"
        assert host.succeed("stat -c %u /var/lib/slot-scratch/alice/home-agent-.cache/mine").strip() == "1000"
        assert host.succeed("stat -c %a /var/lib/slot-scratch /var/lib/slot-scratch/alice").split() == ["700", "700"]

    with subtest("the root quota stops the root, not scratch"):
        in_slot_fail("alice", "${pkgs.coreutils}/bin/dd if=/dev/urandom of=/root/big bs=1M count=300")
        in_slot("alice", "${pkgs.coreutils}/bin/rm -f /root/big")
        in_slot("alice", "${pkgs.coreutils}/bin/dd if=/dev/urandom of=/scratch/big bs=1M count=300")
        host.succeed("sync")
        used = int(host.succeed("zfs get -Hp -o value used tpool/nobackup/slots/alice").strip())
        assert used > 300 * 1024 * 1024, used
        assert host.succeed("zfs get -H -o value com.sun:auto-snapshot tpool/nobackup/slots/alice").strip() == "false"

    with subtest("--finalize drops the old tree"):
        host.succeed("slot-storage-migrate --finalize alice")
        host.fail("test -e /var/lib/nixos-containers/.premigrate-alice")

    with subtest("reset --hard empties both datasets, the slot comes back with its binds"):
        host.succeed("runuser -u alice -- slot reset --hard")
        host.wait_until_succeeds("machinectl show alice -p Leader --value", timeout=90)
        assert host.succeed(f"findmnt -rn -o SOURCE --mountpoint {root}").strip() == "tpool/slots/alice"
        host.fail("test -e /var/lib/slot-scratch/alice/var-tmp/old-file")
        host.fail("test -e /var/lib/slot-scratch/alice/scratch/big")
        host.fail(f"test -e {root}/var/tmp/old-file")
        assert guest_mount_source("alice", "/scratch") == "tpool/nobackup/slots/alice[/scratch]"

    with subtest("a fresh slot gets its datasets at first start"):
        host.succeed("systemctl start container@fresh")
        assert host.succeed("findmnt -rn -o SOURCE --mountpoint /var/lib/nixos-containers/fresh").strip() == "tpool/slots/fresh"
        assert host.succeed("zfs get -H -o value refquota tpool/slots/fresh").strip() == "20G"
        assert host.succeed("zfs get -H -o value quota tpool/nobackup/slots/fresh").strip() == "200G"
        assert guest_mount_source("fresh", "/var/cache") == "tpool/nobackup/slots/fresh[/var-cache]"
        # its data path: an empty dataset, set up as declared
        assert guest_mount_source("fresh", "/var/lib/db") == "tpool/slot-data/fresh/var-lib-db"
        assert in_slot("fresh", stat + "/var/lib/db").strip() == "1000 992 2770"

    dbset = "tpool/slot-data/fresh/var-lib-db"
    db = "/var/lib/nixos-containers/fresh/var/lib/db"
    dbmnt = "/var/lib/slot-data/fresh/var-lib-db"
    getfacl = "${pkgs.acl}/bin/getfacl -n -c "
    # per entry, sorted: path, owner, group, mode, size, links, ACL incl.
    # default ACL (one line each); then the contents' checksums
    listing = (
        "export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.findutils
            pkgs.acl
          ]
        }; "
        + "find . -print0 | sort -z | while IFS= read -r -d \"\" f; do "
        + "printf '%s %s ' \"$f\" \"$(stat -c '%u %g %a %s %h' \"$f\")\"; "
        + "getfacl -n -c -- \"$f\" | paste -sd ,; done; sha256sum file sub/blob"
    )

    def migrations():
        return int(host.succeed("journalctl -u container-slot-storage@fresh | grep -c '/var/lib/db verified (' || true").strip())

    with subtest("data path: own dataset, quota, reservation, snapshotted like the root"):
        assert host.succeed(f"zfs get -H -o value refquota,refreservation {dbset}").split() == ["64M", "64M"]
        assert host.succeed(f"zfs get -H -o value,source com.sun:auto-snapshot {dbset}").split()[0] == "true"
        assert host.succeed("zfs get -H -o value com.sun:auto-snapshot tpool/slots/fresh").strip() == "true"
        assert host.succeed("stat -c %a /var/lib/slot-data /var/lib/slot-data/fresh").split() == ["700", "700"]

    with subtest("data path: data already in the root, a failing copy blocks the start"):
        host.succeed("systemctl stop container@fresh")
        # the slot's data as an older slot left it in its root (guest ids
        # on disk), the mountpoint dir standing in for it
        host.succeed(
            f"rmdir {db} && mkdir -p {db}/sub",
            f"echo hello > {db}/file && head -c 3M /dev/urandom > {db}/sub/blob && ln {db}/file {db}/sub/link",
            f"chown -R 1000:992 {db} && chmod 2770 {db} {db}/sub",
            f"chown 1001:992 {db}/sub/blob",
            f"${pkgs.acl}/bin/setfacl -m g:992:rwx,d:g:992:rwx {db} {db}/sub",
        )
        before = host.succeed(f"cd {db} && " + listing)
        # a dataset that refuses writes: the copy fails
        host.succeed(f"${pkgs.e2fsprogs}/bin/chattr +i {dbmnt}")
        host.fail("systemctl start container@fresh")
        host.succeed("journalctl -u container-slot-storage@fresh | grep -q 'copying /var/lib/nixos-containers/fresh/var/lib/db failed'")
        host.fail("machinectl show fresh -p Leader --value")
        host.succeed(f"${pkgs.e2fsprogs}/bin/chattr -i {dbmnt}")
        assert host.succeed(f"cd {db} && " + listing) == before
        host.fail(f"ls -d {db}.premigrate-*")
        host.succeed(f"test -z \"$(ls -A {dbmnt})\"")

    with subtest("data path: migrated at the next start, same content and ACLs in the guest"):
        host.succeed("systemctl reset-failed container@fresh container-slot-storage@fresh || true")
        host.succeed("systemctl start container@fresh")
        host.wait_until_succeeds("machinectl show fresh -p Leader --value", timeout=90)
        assert migrations() == 1
        host.succeed(f"ls -d {db}.premigrate-*/sub/blob")
        assert host.succeed(f"ls -A {db}").strip() == ""
        assert host.succeed(f"stat -c '%u %g %a' {db}").strip() == "1000 992 2770"
        assert host.succeed(f"{getfacl} {db}") == host.succeed(f"{getfacl} {db}.premigrate-*")
        assert guest_mount_source("fresh", "/var/lib/db") == dbset
        in_guest = in_slot("fresh", "${pkgs.bash}/bin/bash -c " + shlex.quote("cd /var/lib/db && " + listing))
        assert in_guest == before, (in_guest, before)

    with subtest("data path: the guest writes through the group ACL, within the quota"):
        as_member = "${pkgs.util-linux}/bin/setpriv --reuid=1002 --regid=992 --clear-groups "
        in_slot("fresh", as_member + "${pkgs.coreutils}/bin/touch /var/lib/db/sub/new")
        assert in_slot("fresh", stat + "/var/lib/db/sub/new").strip().startswith("1002 992")
        assert "group:992:rwx" in in_slot("fresh", getfacl + "/var/lib/db/sub/new")
        assert host.succeed(f"stat -c '%u %g' {dbmnt}/sub/new").strip() == "1002 992"
        in_slot_fail("fresh", "${pkgs.coreutils}/bin/dd if=/dev/urandom of=/var/lib/db/big bs=1M count=100")
        in_slot("fresh", "${pkgs.coreutils}/bin/rm -f /var/lib/db/big")

    with subtest("data path: a further start copies nothing"):
        host.succeed("systemctl restart container@fresh")
        host.wait_until_succeeds("machinectl show fresh -p Leader --value", timeout=90)
        assert migrations() == 1
        assert host.succeed(f"ls -d {db}.premigrate-* | wc -l").strip() == "1"
        in_slot("fresh", "${pkgs.coreutils}/bin/test -e /var/lib/db/sub/new")
        # the hard link survived the copy
        ino = host.succeed(f"stat -c %i {dbmnt}/file {dbmnt}/sub/link").split()
        assert ino[0] == ino[1], ino

    with subtest("data path: data on both sides, or an unconfigured data dataset, blocks the start"):
        host.succeed("systemctl stop container@fresh")
        host.succeed(f"touch {db}/stray")
        host.fail("systemctl start container@fresh")
        host.succeed("journalctl -u container-slot-storage@fresh | grep -q 'hold data. After an interrupted migration'")
        host.fail("machinectl show fresh -p Leader --value")
        host.succeed(f"test -e {db}/stray && test -e {dbmnt}/sub/new")
        host.succeed(f"rm {db}/stray")
        host.succeed("zfs create -o mountpoint=none tpool/slot-data/fresh/var-lib-gone")
        host.succeed("systemctl reset-failed container@fresh container-slot-storage@fresh || true")
        host.fail("systemctl start container@fresh")
        host.succeed("journalctl -u container-slot-storage@fresh | grep -q 'var-lib-gone is no configured data path'")
        host.fail("machinectl show fresh -p Leader --value")
        host.succeed("zfs destroy tpool/slot-data/fresh/var-lib-gone")
        host.succeed("systemctl reset-failed container@fresh container-slot-storage@fresh || true")
        host.succeed("systemctl start container@fresh")
        host.wait_until_succeeds("machinectl show fresh -p Leader --value", timeout=90)
        assert migrations() == 1

    with subtest("guest module: tool defaults and a cache user's ~/.cache on /scratch"):
        guest.wait_for_unit("multi-user.target")
        guest.wait_for_unit("container-slot-cache-agent.service")
        assert guest.succeed("runuser -l agent -c 'echo $npm_config_cache'").strip() == "/home/agent/.cache/npm"
        assert guest.succeed("env -i sh -c '. /etc/profile; echo $GOMODCACHE'").strip() == "/scratch/.cache/go-mod"
        assert guest.succeed("findmnt -rn -o SOURCE --mountpoint /home/agent/.cache").strip().endswith("[/home/agent/.cache]")
        assert guest.succeed("stat -c %U /scratch/home/agent/.cache /home/agent/.cache").split() == ["agent", "agent"]
        guest.succeed("runuser -u agent -- touch /home/agent/.cache/x")
        guest.succeed("test -e /scratch/home/agent/.cache/x")

    with subtest("guest module: a non-empty ~/.cache is not hidden"):
        guest.wait_for_unit("container-slot-cache-other.service")
        guest.fail("findmnt --mountpoint /home/other/.cache")
        guest.succeed("test -e /home/other/.cache/keep")
        guest.succeed("journalctl -u container-slot-cache-other | grep -q 'holds data'")

    with subtest("guest module: sshd with the host's keys file and host key"):
        guest.wait_for_unit("sshd.service")
        sshd = guest.succeed("sshd -T -f /etc/ssh/sshd_config")
        assert "/var/lib/container-slot/authorized_keys" in sshd, sshd
        assert "HostKey /var/lib/container-slot/ssh_host_ed25519_key" in sshd, sshd
  '';
}
