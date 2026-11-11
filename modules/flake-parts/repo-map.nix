# The hyperconfig-map agent skill's generated part (../../skills/hyperconfig-map,
# ../../tools/repo-map): `nix run .#repo-map` rewrites its
# references/map-*.md from the repo text, and checks.<system>.repo-map
# fails when the committed maps are stale. Text only, no machine eval: the
# check takes seconds, so it can sit in every `nix flake check`.
{ lib, ... }:
let
  # Exactly what the generator reads (and the committed maps): edits
  # elsewhere leave the check's derivation alone.
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../flake.nix
      ../../machines
      ../../modules
      ../../hyperhermes/modules
      ../../tools
      ../../vars
      ../../skills/hyperconfig-map/references
    ];
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.repo-map = pkgs.writeShellApplication {
        name = "repo-map";
        runtimeInputs = [
          pkgs.python3
          pkgs.git
        ];
        text = ''
          root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
          exec python3 ${../../tools/repo-map/repo-map.py} --root "$root" "$@"
        '';
      };

      checks.repo-map = pkgs.runCommand "repo-map-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
        python3 ${../../tools/repo-map/repo-map.py} --root ${src} --check
        touch $out
      '';
    };
}
