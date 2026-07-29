{ pkgs, inputs, lib, ... }:
# The `pi` agent plus Mic92's skill library — split out of the former pi.nix
# when the patched-omp wrappers were dropped in favour of afk (./afk.nix).
# These two are independent of the omp harness: `pi` is its own agent binary
# from llm-agents, and mics-skills packages are plain skill libraries, so they
# survived the omp consolidation unchanged.
let
  sys = pkgs.stdenv.hostPlatform.system;
in
{
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
