# nixosModules.slot: the module every container slot's system imports
# (hyperhermes' modules/slot), exported here so slot deployers take it
# from github:DavHau/hyperconfig. Merges with all-modules.nix's
# nixosModules (modules/nixos/*).
{ inputs, ... }:
{
  flake.nixosModules.slot = inputs.hyperhermes.nixosModules.slot;
}
