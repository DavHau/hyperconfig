{ writeShellApplication, nix, jq, curl, coreutils }:
writeShellApplication {
  name = "hermes-onboard";
  # clan comes from the devshell (it is not a nixpkgs package); the rest is
  # pinned here so the eval, API calls and dates run the same everywhere.
  runtimeInputs = [ nix jq curl coreutils ];
  text = builtins.readFile ./hermes-onboard.sh;
}
