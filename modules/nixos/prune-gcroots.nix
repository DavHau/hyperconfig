# CLI to prune stale auto GC roots (nix-direnv devshells and old result links).
# Usage: prune-gcroots --delete-older-than 30d [--dry-run]
#
# Strategy:
# - dangling links are always deleted
# - direnv devshell roots (target under a .direnv/): deleted if the shell was
#   not *loaded* for the given age. Last load is measured as the max
#   atime/mtime over the project's .direnv/*.rc files — nix-direnv sources the
#   cached rc on every load, bumping its atime (relatime => day granularity).
# - all other roots (result links, etc.): deleted if the auto link itself is
#   older than the given age.
#
# Deleting only unroots; nothing is freed until the next nix GC run.
# Needs write access to /nix/var/nix/gcroots/auto => run with sudo.
{pkgs, ...}: {
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "prune-gcroots";
      text = builtins.readFile ./prune-gcroots.sh;
    })
  ];
}
