{ pkgs, inputs, lib, ... }:
# The `pi` agent plus Mic92's skill library — split out of the former
# pi.nix when the patched-omp wrappers were dropped in favour of afk
# (./afk.nix). These are independent of the omp harness: `pi` is its own
# binary from llm-agents, and mics-skills packages are plain skill
# libraries, so they survived the omp consolidation unchanged.
# herdr moved to ./herdr-jj.nix (wrapped with the jj-workspaces plugin).
let
  sys = pkgs.stdenv.hostPlatform.system;
in
{
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
