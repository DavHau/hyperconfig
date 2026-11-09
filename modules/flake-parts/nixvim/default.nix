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
      system,
      pkgs,
      ...
    }:
    {
      # Not inputs'.nixvim: its perInput probes nixvim's formatter, which
      # lives in nixvim's dev partition, a flake-compat "${./dev}" that
      # read-only eval (flake check --no-build) cannot import. Only on
      # systems nixvim supports (not riscv64-linux).
      packages = lib.optionalAttrs (inputs.nixvim.legacyPackages ? ${system}) {
        nixvim = inputs.nixvim.legacyPackages.${system}.makeNixvimWithModule {
          inherit pkgs;
          extraSpecialArgs = {
            inherit self;
          };
          module.imports = lib.attrValues (readModulesDir ./.);
        };
      };

      # checks."packages/nixvim" = self'.packages.nixvim;
    };
}
