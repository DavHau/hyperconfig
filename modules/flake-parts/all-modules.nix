{config, lib, ...}: let

  modulesDir = ../.;

  moduleKinds = builtins.readDir modulesDir;

  mapModules = kind:
    lib.mapAttrs'
    (fn: _:
      lib.nameValuePair
      (lib.removeSuffix ".nix" fn)
      (modulesDir + "/${kind}/${fn}"))
    (builtins.readDir (modulesDir + "/${kind}"));

  flakePartsModules = lib.attrValues (
    lib.filterAttrs
    (modName: _: modName != "all-modules")
    (mapModules "flake-parts")
  );

  kinds = lib.mapAttrs (kind: _: mapModules kind) moduleKinds;

in {

  imports = flakePartsModules;

  # generates future flake outputs: `modules.<kind>.<module-name>` (the
  # option is flake-parts' flakeModules.modules, imported by ./nixvim)
  config.flake.modules = kinds;

  # comapt to current schema: `nixosModules` / `darwinModules`
  config.flake.nixosModules = kinds.nixos or {};
  config.flake.darwinModules = kinds.darwin or {};
}
