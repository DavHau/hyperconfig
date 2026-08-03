{ pkgs, inputs, lib, ... }:
# The `pi` agent, `herdr`, plus Mic92's skill library — split out of the former
# pi.nix when the patched-omp wrappers were dropped in favour of afk
# (./afk.nix). These are independent of the omp harness: `pi` and `herdr` are
# their own binaries from llm-agents, and mics-skills packages are plain skill
# libraries, so they survived the omp consolidation unchanged.
let
  sys = pkgs.stdenv.hostPlatform.system;
in
{
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    inputs.llm-agents.packages.${sys}.herdr
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
