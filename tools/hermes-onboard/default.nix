{ writeShellApplication, nix, jq }:
writeShellApplication {
  name = "hermes-onboard";
  # clan comes from the devshell (it is not a nixpkgs package); nix and jq
  # are pinned here so the eval runs the same everywhere.
  runtimeInputs = [ nix jq ];
  text = builtins.readFile ./hermes-onboard.sh;
}
