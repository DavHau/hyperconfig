{ lib, ... }: {
  perSystem = { pkgs, ... }: {
    packages = lib.optionalAttrs (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.chromium) {
      web-bench = pkgs.callPackage ../../tools/web-bench { };
    };
  };
}
