/*
  The mm project's market-data store lives on bam's vault
  (/vault/parquet/mm, moved off amy's zroot 2026-10-03) but keeps its
  path: every mm checkout reaches it through `data -> ~/bigfiles/mm`, and
  `mm session check-store` rejects symlinks under the store root, so this
  is a bind mount, not a symlink. sbox binds /home/grmpf/bigfiles
  recursively, so sandboxes started after boot see the vault data too.

  nofail: when bam is unreachable at boot the mount is skipped and
  ~/bigfiles/mm shows the empty local mountpoint instead of hanging boot.
  Requires ./vault-nfs-client.nix.
*/
{
  fileSystems."/home/grmpf/bigfiles/mm" = {
    device = "/vault/parquet/mm";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/vault/parquet/mm"
      "x-systemd.requires-mounts-for=/home/grmpf/bigfiles"
    ];
  };
}
