{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }: {
    devShells.default = inputs.devshell.legacyPackages.${system}.mkShell {
      packages = [
        inputs.agenix.packages.${system}.agenix
      ];
      env = [
        {name="EDITOR"; value="vim";}
      ];
    };
  };
}


