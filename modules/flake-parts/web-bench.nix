{ lib, ... }: {
  perSystem = { pkgs, ... }: {
    # x86_64-linux only: the Camoufox release is a prebuilt x86_64 binary.
    packages = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      web-bench = pkgs.callPackage ../../tools/web-bench { };
    };
  };
}
