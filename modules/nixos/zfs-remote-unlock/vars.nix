# The clan vars generators of a ZFS passphrase and its clevis JWE, shared by
# som (./default.nix) and nas (machines/nas/automount) so both carry the same
# var names: zfs-key/passphrase and zfs-tang/zfs-key.jwe.
#
# A plain function, not a module: nas imports it without the initrd unlock.
#   zfs-key { generate }      the passphrase: secret, deploy = false. With
#                             generate = false the script refuses to run, for
#                             a passphrase that already exists and is set by
#                             hand (`clan vars set`), never invented.
#   zfs-tang { encrypt, ... } the passphrase as a clevis JWE: `encrypt` reads
#                             it on stdin; `check` runs after, on $out.
{ pkgs }:
{
  zfs-key =
    {
      generate ? true,
      refusal ? "zfs-key must be set by hand (clan vars set), never generated",
    }:
    {
      files.passphrase = {
        secret = true;
        # Never installed on the machine whose disk it protects.
        deploy = false;
        # ... but `clan machines install` must hand it to disko before it can
        # create the encrypted dataset. This phase uploads it to the *installer*
        # as /run/partitioning-secrets/zfs-key/passphrase (nixos-anywhere
        # --disk-encryption-keys) and nowhere else. Only the partitioning phase
        # consults neededFor, so deploy = false still holds for the target.
        neededFor = "partitioning";
      };
      runtimeInputs =
        if generate then
          [
            pkgs.coreutils
            pkgs.xkcdpass
          ]
        else
          [ ];
      script =
        if generate then
          ''
            xkcdpass --numwords 6 --delimiter - --count 1 | tr -d "\n" > "$out"/passphrase
          ''
        else
          ''
            echo ${pkgs.lib.escapeShellArg refusal} >&2
            exit 1
          '';
    };

  zfs-tang =
    {
      encrypt,
      check ? "",
      validation,
      runtimeInputs ? [ pkgs.clevis ],
      neededFor ? null,
    }:
    {
      dependencies = [ "zfs-key" ];
      files."zfs-key.jwe" = pkgs.lib.optionalAttrs (neededFor != null) { inherit neededFor; };
      inherit validation runtimeInputs;
      script = ''
        ${encrypt} \
          < "$in/zfs-key/passphrase" > "$out/zfs-key.jwe"
      ''
      + check;
    };
}
