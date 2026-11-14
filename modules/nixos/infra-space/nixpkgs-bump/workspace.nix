# nixpkgs-bump-workspace (./workspace.sh), for ../nixpkgs-bump.nix (the
# guest's PATH) and ./workspace-test.nix.
{
  pkgs,
  repo ? "/home/infra/hyperconfig",
  logDir ? "/home/infra/nixpkgs-bump",
}:
pkgs.writeShellApplication {
  name = "nixpkgs-bump-workspace";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jujutsu
  ];
  text = builtins.replaceStrings [ "@repo@" "@logDir@" ] [ repo logDir ] (
    builtins.readFile ./workspace.sh
  );
}
