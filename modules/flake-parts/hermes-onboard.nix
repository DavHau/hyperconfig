{ ... }: {
  perSystem = { pkgs, ... }: {
    packages.hermes-onboard = pkgs.callPackage ../../tools/hermes-onboard { };
  };
}
