{ writeShellApplication, nix, jq, coreutils }:
writeShellApplication {
  name = "slot-onboard";
  runtimeInputs = [ nix jq coreutils ];
  text = builtins.readFile ./slot-onboard.sh;
}
