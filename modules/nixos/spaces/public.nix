# Every space of ./registry.nix with its machine's mesh address and its
# guest's pinned host key, from the public clan vars (read from the flake
# directory, not from the machines' evaluated configs). Used by
# ./client.nix (Dave's desktops).
#
# A space whose host key is not generated yet (right after it was added,
# before `clan vars generate <machine>`) is left out instead of failing
# the evaluation: the desktops get it with the first deploy after that.
{
  lib,
  clanLib,
  flake,
}:
let
  publicValue =
    machine: generator: file:
    let
      value = clanLib.getPublicValue {
        inherit
          flake
          machine
          generator
          file
          ;
        default = null;
      };
    in
    if value == null then null else lib.trim value;

  spaces = lib.mapAttrs (name: s: {
    inherit (s) machine sshPort;
    user = name;
    address = publicValue s.machine "yggdrasil" "address";
    hostKey = publicValue s.machine "space-${name}-hostkey" "ssh_host_ed25519_key.pub";
  }) (import ./registry.nix);
in
lib.filterAttrs (_: s: s.address != null && s.hostKey != null) spaces
