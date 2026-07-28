{ pkgs, inputs, lib, config, ... }:
# afk: the omp-based harness from the local ../afk flake checkout.
# Default package is the nono-sandboxed variant (private Nix store);
# afk-nosand is deliberately not installed — opt in per host if needed.
#
# Wrapped only to hand it the inference endpoint token: afk owns its own
# profile bootstrap (config.yml, rules, extensions), so the wrapper adds
# nothing but the INFERENCE_API_KEY export. See ./inference-api-key.nix.
let
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
in
{
  environment.systemPackages = [
    (inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = inputs.afk.packages.${pkgs.stdenv.hostPlatform.system}.afk;
      preHook = common.inferenceApiKeyExport;
    })
  ];
}
