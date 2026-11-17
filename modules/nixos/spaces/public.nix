# Every space of ./registry.nix on each of its machines, with that
# machine's mesh address and the guest's pinned host key, from the public
# clan vars (read from the flake directory, not from the machines'
# evaluated configs). Used by ./client.nix (Dave's desktops). The copy on
# a space's first machine is named after the space, a copy on another
# machine <space>-<machine> (its ssh alias space-<space>-<machine>, its
# herdr machine label); the user is the space's name on all of them.
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

  spaces = lib.concatMapAttrs (
    name: s:
    lib.listToAttrs (
      lib.imap0 (
        i: machine:
        lib.nameValuePair (if i == 0 then name else "${name}-${machine}") {
          inherit machine;
          inherit (s) sshPort;
          user = name;
          address = publicValue machine "yggdrasil" "address";
          hostKey = publicValue machine "space-${name}-hostkey" "ssh_host_ed25519_key.pub";
        }
      ) s.machines
    )
  ) (import ./registry.nix);
in
lib.filterAttrs (_: s: s.address != null && s.hostKey != null) spaces
