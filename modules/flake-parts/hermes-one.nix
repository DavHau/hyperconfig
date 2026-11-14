{ lib, ... }: {
  perSystem = { pkgs, ... }: {
    # Hermes One (pkgs/hermes-one), as Dave's desktops build it
    # (modules/nixos/dave-desktop/hermes-one.nix); x86_64-linux only.
    packages = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
      hermes-one = pkgs.callPackage ../../pkgs/hermes-one { };
    };
  };
}
