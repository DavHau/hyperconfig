{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }: {
    devShells.default = pkgs.mkShell {
      packages = [
        inputs'.clan-core.packages.clan-cli
        pkgs.esphome
        # inputs'.nix-multi.packages.nix
      ];
    };
  };
}


