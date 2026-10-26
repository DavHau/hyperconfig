{ lib, ... }: {
  perSystem = { pkgs, inputs', ... }: {
    # x86_64-linux only: the Camoufox release is a prebuilt x86_64 binary.
    packages = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      # Camoufox and CaptchaKraken are hyperhermes' builds (its browser
      # feature), against our nixpkgs through the input's follows.
      web-bench = pkgs.callPackage ../../tools/web-bench {
        inherit (inputs'.hyperhermes.packages) camoufox camoufox-python captchakraken-python;
      };
    };
  };
}
