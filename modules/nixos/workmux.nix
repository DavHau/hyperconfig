{ pkgs, inputs, ... }:
{
  # workmux: git worktrees + tmux windows for running coding agents in parallel.
  #
  # This module only installs the binary. The omp-side integration — discovering
  # workmux's skills, loading the status-reporting extension, and pointing
  # workmux at `pi` as the default agent — lives in ./pi.nix, which wires those
  # into omp's config dir ($HOME/.omp/agent) via the omp wrapper.
  environment.systemPackages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.workmux
  ];
}
