# Keep a ZFS encryption root's `keylocation` pointing at its current key file.
#
# keylocation is a pool property, written once at `zfs create` time and read
# only by `zfs load-key` - in practice at boot. A key file whose path moves
# afterwards (bam, 2026-10: clan-core moved vars secrets to
# /run/secrets/vars/per-machine/<machine>/...) leaves the property stale, and
# the next boot fails "Key load error: Failed to open key material file"
# with every dataset locked.
#
# nixpkgs' zfs-import-<pool> script imports the pool and loads the keys in
# one go, with no hook in between. So this runs as its preStart: import the
# pool (-N, nothing mounted; the same device wait as upstream), point
# keylocation at the configured file, and let the upstream script find the
# pool imported and load the key from the right place. A pool that never
# appears is left to the upstream script and its error.
#
# Tested by the `zfs-keylocation-sync` flake check (./test.nix).
{ config, lib, ... }:
let
  cfg = config.zfsKeylocationSync;
  zfsCfg = config.boot.zfs;
  zpool = "${zfsCfg.package}/sbin/zpool";
  zfs = "${zfsCfg.package}/sbin/zfs";
  poolOf = root: lib.head (lib.splitString "/" root);
  devNodes = pool: if zfsCfg.pools ? ${pool} then zfsCfg.pools.${pool}.devNodes else zfsCfg.devNodes;

  sync = root: keyFile: ''
    pool=${lib.escapeShellArg (poolOf root)}
    for _ in $(seq 1 60); do
      ${zpool} list "$pool" >/dev/null 2>&1 && break
      # shellcheck disable=SC2086
      ${zpool} import -d ${lib.escapeShellArg (devNodes (poolOf root))} -N $ZFS_FORCE "$pool" 2>/dev/null && break
      sleep 1
    done
    if ${zpool} list "$pool" >/dev/null 2>&1; then
      want=${lib.escapeShellArg "file://${keyFile}"}
      have=$(${zfs} get -H -o value keylocation ${lib.escapeShellArg root})
      if [ "$have" != "$want" ]; then
        echo "keylocation of ${root}: $have -> $want"
        ${zfs} set keylocation="$want" ${lib.escapeShellArg root}
      fi
    fi
  '';
in
{
  options.zfsKeylocationSync = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      vault = "/run/secrets/vars/per-machine/bam/vault-key/key";
    };
    description = ''
      Encryption roots (dataset names) mapped to the absolute path of their
      key file. Before the pool's import service loads keys, the root's
      keylocation is set to file://<path> if it differs.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    assertions = lib.mapAttrsToList (root: keyFile: {
      assertion = lib.hasPrefix "/" keyFile;
      message = "zfsKeylocationSync.${root}: key file path must be absolute, got ${keyFile}";
    }) cfg;

    # mkMerge, not an attrset fold: two roots in one pool share the unit, and
    # preStart (lines) concatenates.
    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (root: keyFile: {
        "zfs-import-${poolOf root}".preStart = sync root keyFile;
      }) cfg
    );
  };
}
