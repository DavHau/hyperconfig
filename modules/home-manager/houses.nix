{ pkgs, inputs, config, ... }:
let
  lib = pkgs.lib;

  # Nix >= 2.36pre (fd-based PosixSourceAccessor) opens "/" read-only when it
  # builds its impure-eval root accessor. Every legacy command home-manager's
  # own activation depends on (nix-build sanity check, nix-env --profile --set)
  # therefore dies inside the house with `opening file "/": Permission denied`,
  # because Landlock only grants read_dir beneath the paths in
  # 20-housing.toml. Landlock has no way to allow opening "/" without
  # granting read_dir on the whole tree, so grant exactly that: directory
  # listing only, no read_file / execute outside the housing rules.
  nixRootRule = (pkgs.formats.toml { }).generate "30-nix-root.toml" {
    abi = 6;
    ruleset = [{ handled_access_fs = [ "abi.all" ]; }];
    path_beneath = [{
      allowed_access = [ "read_dir" ];
      parent = [ "/" ];
    }];
  };
in
{
  imports = [
    inputs.nix-housing.homeManagerModules.default
  ];

  housing = {
    enable = true;
    houses = {
     dev = {
       modules = [
       ];
       capabilities = {
         readWritePaths = [

         ];
       };
     };
   };
 };

  xdg.configFile = lib.mapAttrs' (_: h:
    lib.nameValuePair "island/profiles/${h.profileName}/landlock/30-nix-root.toml" {
      source = nixRootRule;
    }) config.housing.houses;
}
