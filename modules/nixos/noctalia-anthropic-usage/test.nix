# Behavior tests for noctalia-anthropic-usage (see default.nix):
#   test-poller.py: the state file the bar widget consumes — logins from
#   all omp agent.dbs, latest-expiring token per account, weekly + Fable
#   percents, previous-state fallback on fetch failure, expired accounts
#   not queried. Stubbed agent.dbs + local HTTP stub, no network.
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
