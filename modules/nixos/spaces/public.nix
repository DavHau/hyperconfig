# Every space-like container Dave reaches from his desktops, one entry per
# copy: each space of ./registry.nix on each of its machines, and
# infra-space on each of its members (../infra-space/public-members.nix).
# Mesh address and the guest's pinned host key come from the public clan
# vars (read from the flake directory, not from the machines' evaluated
# configs). Used by ./client.nix (Dave's desktops).
#
# Keyed `<space>-<machine>`, the copy's ssh alias; its launcher and herdr
# label are "<space> (<machine>)". `herdrId` names the herdr entry's id
# (./herdr-space-machines.py): the name a registry space's copy had before
# this scheme (the first machine's copy was the bare space name), so its
# entry is renamed in place rather than added a second time.
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
    space: s:
    lib.listToAttrs (
      lib.imap0 (
        i: machine:
        lib.nameValuePair "${space}-${machine}" {
          inherit space machine;
          inherit (s) sshPort;
          user = space;
          address = publicValue machine "yggdrasil" "address";
          hostKey = publicValue machine "space-${space}-hostkey" "ssh_host_ed25519_key.pub";
          herdrId = if i == 0 then space else "${space}-${machine}";
        }
      ) s.machines
    )
  ) (import ./registry.nix);

  infraSpace = lib.mapAttrs' (
    machine: m:
    lib.nameValuePair "infra-space-${machine}" {
      inherit machine;
      inherit (m) sshPort address hostKey;
      space = "infra-space";
      user = "infra";
    }
  ) (import ../infra-space/public-members.nix { inherit lib clanLib flake; });
in
infraSpace // lib.filterAttrs (_: s: s.address != null && s.hostKey != null) spaces
