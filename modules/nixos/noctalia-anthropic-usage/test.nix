# Behavior tests for noctalia-anthropic-usage (see default.nix):
#   - test-poller.py: state file the bar widget consumes — two accounts,
#     Fable percents, claude-code / omp-cache / previous-state
#     fallbacks, token refresh + write-back, credential dedupe. Stubbed
#     agent.db + local HTTP stub, no network.
#   - test-merge.sh: the noctalia config seed — per-file symlink
#     materialisation, plugins.json enable, append-only widget wiring,
#     idempotence, fresh host.
#   - strict qmllint (--max-warnings 0) over the plugin QML, with
#     noctalia-shell's runtime `qs.*` modules resolvable via the shared
#     spaces harness — catches broken imports/typos that otherwise only
#     surface as a silently missing bar widget at runtime.
#
# `pkgs` must carry the spaces overlay (noctalia-shell, quickshell);
# `spaces` is the spaces flake input source (for lib/qmllint.nix).
{ pkgs, spaces }:
let
  qmllint = import "${spaces}/lib/qmllint.nix" pkgs;
  noctaliaImports = qmllint.mkQsImports {
    name = "noctalia";
    tree = "${pkgs.noctalia-shell}/share/noctalia-shell";
  };
in
pkgs.runCommand "noctalia-anthropic-usage-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.jq
      pkgs.bash
      pkgs.qt6.qtdeclarative
    ];
    src = ./.;
    qsImports = noctaliaImports;
    qsModules = qmllint.quickshellShim;
    qtModules = "${pkgs.qt6.qtdeclarative}/lib/qt-6/qml";
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    POLLER=$src/poller.py python3 $src/test-poller.py
    MERGE=$src/merge.sh bash $src/test-merge.sh

    mapfile -t files < <(find "$src/plugin" -name '*.qml' | sort)
    qmllint \
      -I "$qsImports" \
      -I "$qsModules" \
      -I "$qtModules" \
      --max-warnings 0 \
      "''${files[@]}"
    echo "ok: plugin QML lints clean"

    touch $out
  ''
