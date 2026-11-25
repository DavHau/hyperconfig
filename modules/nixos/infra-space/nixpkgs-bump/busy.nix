# nixpkgs-bump-busy (./busy.sh), for ../nixpkgs-bump.nix (the unit's
# no-overlap check) and ./busy-test.nix.
{
  pkgs,
  # the infra agent's hermes state
  stateDb,
  # the bump sessions' cwd (agent-job.nix's --in, the job's log dir)
  cwd,
}:
pkgs.writeShellApplication {
  name = "nixpkgs-bump-busy";
  runtimeInputs = [ pkgs.sqlite ];
  text = builtins.replaceStrings [ "@stateDb@" "@cwd@" ] [ stateDb cwd ] (builtins.readFile ./busy.sh);
}
