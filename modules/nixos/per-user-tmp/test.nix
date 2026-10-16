# Per-user /tmp (./default.nix) on a ZFS /tmp emptied at boot
# (../zfs-ephemeral-tmp.nix). alice and bob each see only their own temp
# files, over ssh, su and their systemd user manager; a system service
# running as alice with the instance binds (as the hermes agents have)
# shares her view; root sees everything. Leftovers in the shared dirs move
# into their owners' instances at boot, stale systemd-private dirs go, and
# a reboot empties /tmp but not /var/tmp.
{ pkgs }:
let
  inherit (pkgs) lib;
  sshKey = pkgs.runCommand "per-user-tmp-test-key" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -f $out/key
  '';
  user = name: {
    isNormalUser = true;
    openssh.authorizedKeys.keyFiles = [ "${sshKey}/key.pub" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "per-user-tmp";

  nodes.machine = { config, ... }: {
    imports = [
      ./default.nix
      ../zfs-ephemeral-tmp.nix
    ];
    virtualisation.emptyDiskImages = [ 512 ];
    boot.supportedFilesystems = [ "zfs" ];
    networking.hostId = "8425e349";
    boot.zfs.extraPools = [ "tpool" ];
    # Virtio disks have no /dev/disk/by-id entry.
    boot.zfs.devNodes = "/dev";
    # Stands in for the installer: the pool and the empty dataset exist
    # before the first boot imports them.
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
        zpool create -f tpool /dev/vdb
        zfs create -o mountpoint=legacy tpool/tmp
        zfs snapshot tpool/tmp@blank
        zpool export tpool
      '';
    };
    # The test VM's mounts come from virtualisation.fileSystems.
    virtualisation.fileSystems."/tmp" = {
      device = "tpool/tmp";
      fsType = "zfs";
      # mkVMOverride replaces the module's fileSystems."/tmp".options here.
      options = [
        "nofail"
        "x-systemd.before=local-fs.target"
      ];
    };

    hyper.zfsEphemeralTmp.dataset = "tpool/tmp";
    hyper.perUserTmp.enable = true;

    users.users.alice = user "alice";
    users.users.bob = user "bob";
    services.openssh.enable = true;

    systemd.services.agent-alice = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "alice";
        BindPaths = [
          "/tmp/.inst/alice:/tmp"
          "/var/tmp/.inst/alice:/var/tmp"
        ];
        ExecStart = "${pkgs.bash}/bin/bash -c 'touch /tmp/from-service && exec sleep infinity'";
      };
    };
  };

  testScript = ''
    def ssh(user, cmd):
        # -n: ssh would otherwise read the test driver's command stream.
        return f"ssh -n -i /root/key -o StrictHostKeyChecking=no -o BatchMode=yes {user}@localhost '{cmd}'"

    machine.wait_for_unit("multi-user.target")

    with subtest("first boot: /tmp already on the dataset; plant leftovers"):
        machine.succeed("test \"$(findmnt -no SOURCE,FSTYPE /tmp)\" = 'tpool/tmp zfs'")
        machine.succeed(
            "install -o alice -m 600 /dev/null /var/tmp/alice-leftover",
            "install -d -o bob /var/tmp/systemd-private-00000000000000000000000000000000-x.service-abc",
            "install -o root /dev/null /var/tmp/root-file",
        )
        # Outside boot the sweep leaves running sessions' files alone.
        machine.succeed("systemctl restart per-user-tmp-sweep.service")
        machine.succeed("test -e /var/tmp/alice-leftover")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("sshd.service")
        machine.succeed("install -m 600 ${sshKey}/key /root/key")

    with subtest("/tmp is the rolled-back ZFS dataset"):
        machine.succeed("test \"$(findmnt -no SOURCE,FSTYPE /tmp)\" = 'tpool/tmp zfs'")
        machine.succeed("systemctl is-active tmp-rollback.service")

    with subtest("boot sweep moved alice's leftover, dropped the stale private dir"):
        machine.succeed("test -e /var/tmp/.inst/alice/alice-leftover")
        machine.fail("test -e /var/tmp/alice-leftover")
        machine.fail("ls -d /var/tmp/systemd-private-0000*")
        machine.succeed("test -e /var/tmp/root-file")

    with subtest("each user sees only their own temp files"):
        machine.succeed(ssh("alice", "touch /tmp/a-ssh /var/tmp/a-ssh"))
        machine.succeed(ssh("bob", "touch /tmp/b-ssh"))
        machine.succeed(ssh("alice", "test -e /tmp/a-ssh && test ! -e /tmp/b-ssh"))
        machine.succeed(ssh("bob", "test ! -e /tmp/a-ssh && test ! -e /var/tmp/a-ssh"))
        machine.succeed(ssh("bob", "test -z \"$(ls -A /tmp)\" || ! ls -A /tmp | grep -q a-"))
        machine.fail(ssh("bob", "ls /tmp/.inst/alice"))
        machine.succeed(ssh("alice", "test -e /var/tmp/alice-leftover"))

    with subtest("su and the user manager get the same private view"):
        machine.succeed("su - alice -c 'test -e /tmp/a-ssh'")
        machine.succeed("su - bob -c 'test ! -e /tmp/a-ssh'")
        machine.succeed("loginctl enable-linger alice")
        machine.wait_for_unit("user@1000.service")
        machine.succeed("systemd-run -M alice@ --user --wait --pipe ${pkgs.runtimeShell} -c 'touch /tmp/a-user && test -e /tmp/a-ssh'")

    with subtest("a service with the instance binds shares the user's view"):
        machine.wait_for_unit("agent-alice.service")
        machine.succeed(ssh("alice", "test -e /tmp/from-service"))
        machine.succeed(ssh("bob", "test ! -e /tmp/from-service"))

    with subtest("root sees everything; nothing leaks into the host namespace"):
        machine.succeed("test -e /tmp/.inst/alice/a-ssh -a -e /tmp/.inst/alice/a-user -a -e /tmp/.inst/bob/b-ssh")
        machine.succeed("test \"$(stat -c %a /tmp/.inst)\" = 0")
        machine.fail("test -e /tmp/a-ssh")
        machine.succeed("test \"$(findmnt -n /tmp | wc -l)\" = 1")

    with subtest("reboot empties /tmp, keeps /var/tmp"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")
        machine.fail("test -e /tmp/.inst/alice/a-ssh")
        machine.succeed("test -d /tmp/.inst/alice")
        machine.succeed("test -e /var/tmp/.inst/alice/a-ssh")
  '';
}
