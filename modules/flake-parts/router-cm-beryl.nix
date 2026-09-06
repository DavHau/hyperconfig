{ self, lib, inputs, ... }: {
  perSystem = { config, self', inputs', pkgs, system, ... }: {
    packages.router-cm-beryl = pkgs.callPackage ../../tools/router-cm-beryl { };
  };
}
