{ pkgs, inputs, ... }:
# The `pi` agent, split out of the former pi.nix when the patched-omp
# wrappers were dropped in favour of afk (./afk.nix). `pi` is its own binary
# from llm-agents, independent of the omp harness.
# herdr moved to ./herdr-jj.nix (wrapped with the jj-workspaces plugin).
{
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi
  ];
}
