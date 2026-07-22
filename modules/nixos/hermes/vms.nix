# VM registration: one microvm.nix guest per configured user, built from
# the per-user guest module in ./guest.nix.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  guestConfig = import ./guest.nix { inherit lib pkgs inputs hlib cfg; };
in
{
  config = lib.mkIf cfg.enable {
    microvm.vms = lib.mapAttrs' (user: ucfg:
      lib.nameValuePair (hlib.vmName user) {
        config = guestConfig user ucfg;
        # default for fully-declarative VMs; listed for greppability
        autostart = true;
      }
    ) cfg.users;
  };
}
