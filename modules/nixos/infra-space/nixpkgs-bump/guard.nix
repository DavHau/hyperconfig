# nixpkgs-bump-guard (./guard.sh), for ../nixpkgs-bump.nix (the guest's
# PATH) and ./guard-test.nix (which passes stubs as nix and curl).
{
  pkgs,
  nix ? pkgs.nix,
  curl ? pkgs.curl,
  logDir ? "/home/infra/nixpkgs-bump",
  # ./searxng.nix's age gate
  minAgeHours ? 72,
}:
pkgs.writeShellApplication {
  name = "nixpkgs-bump-guard";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    curl
    pkgs.git
    pkgs.gnugrep
    pkgs.jq
    pkgs.jujutsu
    nix
  ];
  text = builtins.replaceStrings [ "@logDir@" "@minAgeHours@" ] [ logDir (toString minAgeHours) ] (
    builtins.readFile ./guard.sh
  );
}
