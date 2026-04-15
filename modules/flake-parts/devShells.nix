{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }:
    let
      nixEvalCache = inputs.nix-eval-cache.packages.${system}.nix-cli;
      clan-fast = inputs.wrappers.lib.wrapPackage {
        inherit pkgs;
        package = inputs'.clan-core.packages.clan-cli;
        binName = "clan-fast";
        preHook = ''
          export PATH=${nixEvalCache}/bin:$PATH
          export _NIX_TRACING_CACHE_LOGGING=1
        '';
      };
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs'.clan-core.packages.clan-cli
          clan-fast
          # pkgs.esphome
        ];
      };
    };
}
