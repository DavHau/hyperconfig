{inputs, pkgs, ...}: {
  environment.systemPackages = [
    inputs.nix-heuristic-gc.packages.${pkgs.system}.default
  ];
}
