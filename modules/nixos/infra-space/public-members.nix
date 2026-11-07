# Every member of ./members.nix with its mesh address and its container's
# pinned host key, from the members' public clan vars (read from the flake
# directory, not from their evaluated configs). Used by ./default.nix (the
# members' default) and ./launchers.nix (Dave's desktops).
{
  lib,
  clanLib,
  flake,
}:
let
  publicValue =
    machine: generator: file:
    lib.trim (
      clanLib.getPublicValue {
        inherit
          flake
          machine
          generator
          file
          ;
      }
    );
in
lib.mapAttrs (machine: m: {
  inherit (m) sshPort;
  address = publicValue machine "yggdrasil" "address";
  hostKey = publicValue machine "infra-space-hostkey" "ssh_host_ed25519_key.pub";
}) (import ./members.nix)
