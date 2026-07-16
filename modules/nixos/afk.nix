{ pkgs, inputs, ... }:
# afk: the omp-based harness from the local ../afk flake checkout.
# Default package is the nono-sandboxed variant (private Nix store);
# afk-nosand is deliberately not installed — opt in per host if needed.
{
  environment.systemPackages = [
    inputs.afk.packages.${pkgs.stdenv.hostPlatform.system}.afk
  ];
}
