{ ... }: {
  perSystem = { pkgs, ... }: {
    packages.slot-onboard = pkgs.callPackage ../../tools/slot-onboard { };
  };
}
