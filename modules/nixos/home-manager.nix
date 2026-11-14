# home-manager as a NixOS module on Dave's desktops (shared settings for
# every home-manager user; per-user profiles in ./user-dave.nix and
# ./user-grmpf.nix).
{ pkgs, lib, inputs, ... }: {

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit inputs; };
}
