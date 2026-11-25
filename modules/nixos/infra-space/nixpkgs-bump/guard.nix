# nixpkgs-bump-guard (./guard.sh), for ../nixpkgs-bump.nix (the guest's
# PATH) and ./guard-test.nix (which passes stubs as nix and curl).
{
  pkgs,
  nix ? pkgs.nix,
  curl ? pkgs.curl,
}:
pkgs.writeShellApplication {
  name = "nixpkgs-bump-guard";
  runtimeInputs = [
    pkgs.coreutils
    curl
    pkgs.git
    pkgs.gnugrep
    pkgs.jq
    pkgs.jujutsu
    nix
  ];
  text = builtins.readFile ./guard.sh;
}
