# Behavior tests for noctalia-anthropic-usage (see default.nix):
#   test-poller.py: the state file the bar widget consumes — accounts from
#   TeamClaude's /teamclaude/status fetched with the client key as
#   x-api-key, weekly + Fable ratios as percents, reset epoch ms passed
#   through, previous values kept stale on any failure (HTTP error, wrong
#   key, missing key file, bad response). Local HTTP stub, no network.
{ pkgs }:
pkgs.runCommand "noctalia-anthropic-usage-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    # Only the files the test reads; unrelated edits here don't re-run it.
    src = pkgs.lib.fileset.toSource {
      root = ./.;
      fileset = pkgs.lib.fileset.unions [
        ./poller.py
        ./test-poller.py
      ];
    };
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    POLLER=$src/poller.py python3 $src/test-poller.py
    touch $out
  ''
