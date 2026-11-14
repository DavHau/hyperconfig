# Repo hygiene lint (../../tools/hygiene, rules in ../../CONVENTIONS.md):
# unimported modules, dangling path references, off-scheme clan vars
# generator names, ssh keys pasted outside ../admin-ssh-keys.nix, machine
# files over their line budget. checks.<system>.hygiene fails only on
# violations missing from tools/hygiene/baseline.txt; `nix run .#hygiene
# -- --report` lists all of them (the weekly hygiene job). Text only, no
# eval: seconds, like ./repo-map.nix.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.hygiene = pkgs.writeShellApplication {
        name = "hygiene";
        runtimeInputs = [
          pkgs.python3
          pkgs.git
        ];
        text = ''
          root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
          exec python3 ${../../tools/hygiene/hygiene.py} --root "$root" "$@"
        '';
      };

      # The whole tree: a dangling-reference check needs to see every file.
      checks.hygiene = pkgs.runCommand "hygiene-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 ${../../tools/hygiene/hygiene.py} --root ${../..}
        touch $out
      '';
    };
}
