{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }: {
    packages.router-ais = pkgs.callPackage ../../tools/router-ais { };
  };
}
