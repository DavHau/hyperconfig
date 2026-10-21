# An encrypted pool whose keylocation names a key file that no longer exists
# (the key moved, as clan's vars did on bam) still unlocks and mounts at boot:
# the import service repoints keylocation at the configured file first.
{ pkgs }:
let
  passphrase = "keylocation-sync-test";
in
pkgs.testers.runNixOSTest {
  name = "zfs-keylocation-sync";

  nodes.machine = { config, ... }: {
    imports = [ ./default.nix ];
    virtualisation.emptyDiskImages = [ 512 ];
    boot.supportedFilesystems = [ "zfs" ];
    networking.hostId = "8425e349";
    boot.zfs.extraPools = [ "tpool" ];
    boot.zfs.devNodes = "/dev";
    boot.zfs.requestEncryptionCredentials = [ "tpool" ];

    # Where the key lives now.
    environment.etc."tpool-key".text = passphrase;
    zfsKeylocationSync.tpool = "/etc/tpool-key";

    # Stands in for the pool's creation long ago: keylocation names a file
    # that is gone by the time the import runs. Only on the first boot.
    systemd.services.make-tpool = {
      requiredBy = [ "zfs-import-tpool.service" ];
      before = [ "zfs-import-tpool.service" ];
      requires = [ "dev-vdb.device" ];
      after = [ "dev-vdb.device" ];
      unitConfig.DefaultDependencies = false;
      unitConfig.ConditionPathExists = "!/var/lib/tpool-made";
      serviceConfig.Type = "oneshot";
      path = [ config.boot.zfs.package ];
      script = ''
        printf %s ${passphrase} > /run/old-key
        zpool create -O encryption=on -O keyformat=passphrase \
          -O keylocation=file:///run/old-key -O mountpoint=/data tpool /dev/vdb
        zfs create tpool/inner
        zpool export tpool
        rm /run/old-key
        mkdir -p /var/lib && touch /var/lib/tpool-made
      '';
    };
  };

  testScript = ''
    machine.wait_for_unit("zfs-import-tpool.service")
    machine.wait_for_unit("zfs-mount.service")

    with subtest("a stale keylocation is repointed and the pool unlocks"):
        machine.succeed("test -e /var/lib/tpool-made")
        machine.succeed("test ! -e /run/old-key")
        assert machine.succeed("zfs get -H -o value keylocation tpool").strip() == "file:///etc/tpool-key"
        assert machine.succeed("zfs get -H -o value keystatus tpool/inner").strip() == "available"
        machine.succeed("findmnt /data/inner")

    with subtest("the next boot unlocks without touching it again"):
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("zfs-mount.service")
        machine.succeed("findmnt /data/inner")
        machine.fail("journalctl -b -u zfs-import-tpool.service | grep -q 'keylocation of tpool'")
  '';
}
