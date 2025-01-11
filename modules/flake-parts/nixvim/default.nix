{
  lib,
  config,
  self,
  inputs,
  ...
}:
let
  readModulesDir =
    path:
    lib.pipe path [
      builtins.readDir
      (lib.filterAttrs (name: _: (!(lib.hasPrefix "_" name)) && (name != "default.nix")))
      (lib.mapAttrs' (name: type: lib.nameValuePair (lib.removeSuffix ".nix" name) (path + "/${name}")))
    ];
in
{
  imports = [
    inputs.flake-parts.flakeModules.modules
  ];
  # flake.modules.nixvim = readModulesDir ./.;
  perSystem =
    {
      inputs',
      self',
      pkgs,
      ...
    }:
    {
      packages.nixvim = inputs'.nixvim.legacyPackages.makeNixvimWithModule {
        inherit pkgs;
        extraSpecialArgs = {
          inherit self;
        };
        module.imports = lib.attrValues (readModulesDir ./.);
      };

      checks."packages/nixvim" = self'.packages.nixvim;
    };
}
