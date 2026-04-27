{inputs, pkgs, ...}: {
  environment.systemPackages = [
    inputs.nix-heuristic-gc.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
