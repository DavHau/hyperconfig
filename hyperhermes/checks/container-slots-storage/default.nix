# Slot storage (../../modules/container-slots-storage) on a test pool:
# alice's agent slot starts on a root that already holds data, so it runs
# on its directory without scratch binds; slot-storage-migrate refuses a
# root above its quota, then moves it onto its datasets: the old /var/tmp
# contents land in the scratch dataset, the guest sees /scratch, /var/tmp,
# /var/lib/docker and an extra /home/agent/.cache with the declared owners
# and can write there as that user, the root quota stops writes in the
# root only. --finalize drops the old tree; `slot reset --hard` empties
# both datasets and the slot comes back with its binds. A fresh slot gets
# its datasets at first start. The guest module (nixosModules.slot) on a
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
          storage.enable = true;
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
        host.succeed("zpool create -O mountpoint=none -O acltype=posix -O xattr=sa tpool /dev/disk/by-id/virtio-tpool")
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
