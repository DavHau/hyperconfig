# Entity storage (./default.nix) on a ZFS pool on an empty disk. carol, a
# fresh account, gets her datasets at boot; alice's existing home (cache,
# a big directory, hardlinks, a sparse file, a socket, an xattr, a file
# of another uid) is refused until entity-storage-migrate moves it, with
# her agent service, socket-activated forwarder, user manager and linger
# stopped meanwhile and restored after. Then: layout, snapshot property,
# limits, symlinks to scratch, idempotence, reboot, finalize, a quota
# change on switch and a newly listed user whose home is not shadowed.
{ pkgs }:
let
  inherit (pkgs) lib;
in
pkgs.testers.runNixOSTest {
  name = "entity-storage";

  nodes.machine =
    { config, ... }:
    {
      imports = [ ./default.nix ];
      virtualisation.emptyDiskImages = [ 1024 ];
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "8425e349";
      boot.zfs.extraPools = [ "tpool" ];
      # Virtio disks have no /dev/disk/by-id entry.
      boot.zfs.devNodes = "/dev";
      # Stands in for the installer: som's pool shape (a snapshotted root,
      # a nobackup dataset with snapshots off) before the first boot.
      systemd.services.make-tpool = {
        requiredBy = [ "zfs-import-tpool.service" ];
        before = [ "zfs-import-tpool.service" ];
        requires = [ "dev-vdb.device" ];
        after = [ "dev-vdb.device" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        path = [ config.boot.zfs.package ];
        script = ''
          zpool import tpool 2>/dev/null && zpool export tpool && exit 0
          zpool create -f -O mountpoint=none -O acltype=posixacl -O xattr=sa tpool /dev/vdb
          zfs create -o com.sun:auto-snapshot=true tpool/root
          zfs create -o com.sun:auto-snapshot=false tpool/root/nobackup
          zpool export tpool
        '';
      };

      # alice's home as it was before entity storage, planted once.
      systemd.services.seed-alice = {
        wantedBy = [ "multi-user.target" ];
        before = [ "entity-storage.service" ];
        after = [ "local-fs.target" ];
        unitConfig.DefaultDependencies = false;
        unitConfig.ConditionPathExists = "!/var/lib/seeded";
        serviceConfig.Type = "oneshot";
        path = [
          pkgs.coreutils
          pkgs.attr
        ];
        script = ''
          h=/home/alice
          mkdir -p $h/.cache/pip $h/big $h/work/proj $h/work/data $h/scratch \
            $h/.local/share/containers/storage $h/.local/state/sbox
          head -c 2M /dev/urandom > $h/.cache/pip/blob
          head -c 40M /dev/urandom > $h/big/blob
          head -c 10M /dev/urandom > $h/work/data/blob
          head -c 1M /dev/urandom > $h/.local/share/containers/storage/layer
          echo state > $h/.local/state/sbox/s
          echo notes > $h/scratch/notes
          echo hello > $h/work/proj/file
          ln $h/work/proj/file $h/work/proj/hardlink
          truncate -s 1G $h/work/sparse
          setfattr -n user.tag -v kept $h/work/proj/file
          ${pkgs.python3Minimal}/bin/python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("/home/alice/work/sock")'
          chown -R alice:users $h
          echo foreign > $h/work/foreign
          chown 4242:4242 $h/work/foreign
          touch /var/lib/seeded
        '';
      };

      users.users.alice = {
        isNormalUser = true;
        linger = true;
      };
      users.users.carol.isNormalUser = true;
      users.users.dan.isNormalUser = true;
      environment.systemPackages = [ pkgs.attr ];

      # Like hermes-agent-<user>: a system service as the user, in her home.
      systemd.services.agent-alice = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          User = "alice";
          WorkingDirectory = "/home/alice";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      # Like hyperhermes' forwarders: Accept=yes instances as the user.
      systemd.sockets.alice-echo = {
        wantedBy = [ "sockets.target" ];
        listenStreams = [ "127.0.0.1:7777" ];
        socketConfig.Accept = true;
      };
      systemd.services."alice-echo@" = {
        serviceConfig = {
          User = "alice";
          ExecStart = "${pkgs.coreutils}/bin/cat";
          StandardInput = "socket";
        };
      };

      hyper.entityStorage = {
        enable = true;
        dataset = "tpool/root";
        defaults.homeQuota = "32M";
        defaults.scratchQuota = "256M";
        users.alice = { };
        users.carol.scratchQuota = "64M";
      };

      specialisation.changed.configuration = {
        hyper.entityStorage.users.alice.homeQuota = "48M";
        hyper.entityStorage.users.dan = { };
      };
      # dan has lived here before he is listed.
      systemd.tmpfiles.rules = [ "f /home/dan/keep 0600 dan users - mine" ];
    };

  testScript = ''
    def last_run():
        inv = machine.succeed("systemctl show -p InvocationID --value entity-storage.service").strip()
        return machine.succeed(f"journalctl -o cat _SYSTEMD_INVOCATION_ID={inv}")

    def source(path):
        return machine.succeed(f"findmnt -n -o SOURCE --mountpoint {path}").strip()

    def prop(p, ds):
        return machine.succeed(f"zfs get -H -p -o value {p} {ds}").strip()

    files = "big/blob work/data/blob .cache/pip/blob work/proj/file .local/share/containers/storage/layer"
    sums = "cd /home/alice && sha256sum " + files

    machine.wait_for_unit("multi-user.target")

    with subtest("boot: carol gets her datasets, alice's home is refused, not shadowed"):
        machine.succeed("systemctl is-failed entity-storage.service")
        log = last_run()
        assert "alice: REFUSED: /home/alice is not empty" in log, log
        assert "carol: created tpool/root/home/carol" in log, log
        assert source("/home/carol") == "tpool/root/home/carol"
        assert source("/home/carol/scratch") == "tpool/root/nobackup/scratch/carol"
        assert source("/home/carol/.cache") == "tpool/root/nobackup/scratch/carol/cache"
        assert prop("quota", "tpool/root/nobackup/scratch/carol") == str(64 * 2**20)
        machine.succeed("test \"$(stat -c '%U %a' /home/carol/.local)\" = 'carol 700'")
        machine.fail("zfs list tpool/root/home/alice")
        machine.succeed("test -s /home/alice/big/blob")
        before = machine.succeed(sums)
        machine.wait_for_unit("agent-alice.service")
        machine.wait_for_unit("user@1000.service")

    with subtest("migration refuses foreign mounts and a home over its quota"):
        machine.succeed("mkdir /home/alice/mnt && mount -t tmpfs none /home/alice/mnt")
        out = machine.fail("entity-storage-migrate alice --to-scratch big 2>&1")
        assert "mounted below /home/alice" in out, out
        machine.succeed("umount /home/alice/mnt && rmdir /home/alice/mnt")
        out = machine.fail("entity-storage-migrate alice 2>&1")
        assert "does not fit into 32M" in out and "big" in out, out
        out = machine.succeed("entity-storage-migrate alice --to-scratch big --to-scratch work/data --dry-run 2>&1")
        assert "agent-alice.service" in out and "alice-echo.socket" in out, out
        machine.fail("zfs list tpool/root/home/alice")
        machine.succeed("systemctl is-active agent-alice.service")

    with subtest("a process in the home aborts after the stop and restores what was stopped"):
        machine.succeed("systemd-run --unit=holder -p WorkingDirectory=/home/alice ${pkgs.coreutils}/bin/sleep 600")
        out = machine.fail("entity-storage-migrate alice --to-scratch big --to-scratch work/data 2>&1")
        assert "processes still use /home/alice" in out, out
        machine.succeed("systemctl stop holder")
        machine.fail("zfs list tpool/root/home/alice")
        machine.succeed("systemctl is-active agent-alice.service alice-echo.socket")
        machine.succeed("test -e /var/lib/systemd/linger/alice")
        machine.wait_for_unit("user@1000.service")

    with subtest("migration"):
        out = machine.succeed("entity-storage-migrate alice --to-scratch big --to-scratch work/data 2>&1")
        print(out)
        assert "alice-echo.socket" in out and "user@1000.service" in out, out

    with subtest("layout, snapshot property, ownership"):
        assert source("/home/alice") == "tpool/root/home/alice"
        assert source("/home/alice/scratch") == "tpool/root/nobackup/scratch/alice"
        assert source("/home/alice/.cache") == "tpool/root/nobackup/scratch/alice/cache"
        assert source("/home/alice/.local/share/containers") == "tpool/root/nobackup/scratch/alice/containers"
        assert source("/home/alice/.local/state/sbox") == "tpool/root/nobackup/scratch/alice/sbox-state"
        machine.succeed("test \"$(zfs get -H -o value,source com.sun:auto-snapshot tpool/root/home/alice)\" = \"$(printf 'true\\tinherited from tpool/root')\"")
        machine.succeed("test \"$(zfs get -H -o value,source com.sun:auto-snapshot tpool/root/nobackup/scratch/alice/cache)\" = \"$(printf 'false\\tinherited from tpool/root/nobackup')\"")
        assert prop("refquota", "tpool/root/home/alice") == str(32 * 2**20)
        assert prop("quota", "tpool/root/nobackup/scratch/alice") == str(256 * 2**20)
        machine.succeed("test \"$(stat -c '%U %a' /home/alice)\" = 'alice 700'")
        machine.succeed("test \"$(stat -c '%U %a' /home/alice/scratch)\" = 'alice 700'")
        machine.succeed("test \"$(stat -c '%U %a' /home/alice/.cache)\" = 'alice 700'")
        machine.succeed("test -d /home/.premigrate-alice/big")
        machine.fail("test -e /home/.migrate-alice")

    with subtest("data, symlinks into scratch, special files"):
        assert machine.succeed(sums) == before
        machine.succeed("test \"$(readlink /home/alice/big)\" = scratch/big")
        machine.succeed("test \"$(readlink /home/alice/work/data)\" = ../scratch/work/data")
        machine.succeed("su alice -c 'cat /home/alice/big/blob /home/alice/scratch/notes > /dev/null'")
        machine.succeed("test \"$(stat -c %h /home/alice/work/proj/file)\" = 2")
        machine.succeed("test \"$(stat -c %u /home/alice/work/foreign)\" = 4242")
        machine.succeed("test -S /home/alice/work/sock")
        machine.succeed("test \"$(getfattr --only-values -n user.tag /home/alice/work/proj/file)\" = kept")
        machine.succeed("test \"$(stat -c %s /home/alice/work/sparse)\" = 1073741824")
        machine.succeed("test \"$(du -B1 /home/alice/work/sparse | cut -f1)\" -lt 1048576")
        machine.succeed("test \"$(stat -c %U /home/alice/scratch/work)\" = alice")

    with subtest("what was stopped runs again"):
        machine.succeed("systemctl is-active agent-alice.service alice-echo.socket")
        machine.wait_for_unit("user@1000.service")
        machine.succeed("test -e /var/lib/systemd/linger/alice")
        machine.fail("test -e /var/lib/entity-storage/stopped-alice")

    with subtest("limits: the home's refquota, not scratch, stops writes"):
        machine.fail("su alice -c 'dd if=/dev/urandom of=/home/alice/fill bs=1M count=64'")
        machine.succeed("rm -f /home/alice/fill")
        machine.succeed("su alice -c 'dd if=/dev/urandom of=/home/alice/scratch/fill bs=1M count=64'")
        machine.succeed("rm -f /home/alice/scratch/fill")

    with subtest("reconciler is idempotent and the tool will not run twice"):
        machine.succeed("systemctl restart entity-storage.service")
        machine.succeed("systemctl restart entity-storage.service")
        log = last_run()
        assert "alice: unchanged" in log and "carol: unchanged" in log, log
        machine.fail("entity-storage-migrate alice")

    with subtest("reboot: everything mounts again, nothing changes"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.succeed("systemctl is-active entity-storage.service")
        assert "alice: unchanged" in last_run()
        assert source("/home/alice/.local/share/containers") == "tpool/root/nobackup/scratch/alice/containers"
        machine.wait_for_unit("agent-alice.service")
        machine.wait_for_unit("user@1000.service")
        assert machine.succeed(sums) == before

    with subtest("finalize"):
        machine.succeed("entity-storage-migrate --finalize alice")
        machine.fail("test -e /home/.premigrate-alice")
        machine.fail("entity-storage-migrate --finalize alice")

    with subtest("switch: a quota change applies, a newly listed user's home is not shadowed"):
        machine.execute("/run/current-system/specialisation/changed/bin/switch-to-configuration test")
        log = last_run()
        assert "alice: set refquota=48M" in log, log
        assert "dan: REFUSED: /home/dan is not empty" in log, log
        assert prop("refquota", "tpool/root/home/alice") == str(48 * 2**20)
        machine.fail("zfs list tpool/root/home/dan")
        machine.succeed("test \"$(cat /home/dan/keep)\" = mine")
  '';
}
