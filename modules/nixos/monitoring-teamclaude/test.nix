# The TeamClaude usage pipeline's logic, without a VM: som's per-client and
# account exporter (../teamclaude-gateway/usage-metrics.mjs) against
# TeamClaude's own usage store, and the ledger behind the usage pages
# (./ledger.py). checks.x86_64-linux.monitoring-teamclaude in flake.nix.
{ pkgs, package }:
pkgs.runCommand "monitoring-teamclaude-test" { nativeBuildInputs = [ pkgs.nodejs pkgs.python3 ]; } ''
  mkdir scratch
  node --no-warnings ${../teamclaude-gateway/usage-metrics-test.mjs} \
    ${package}/share/teamclaude/src ${../teamclaude-gateway/usage-metrics.mjs} "$PWD/scratch"
  cp ${./ledger.py} ledger.py
  cp ${./test_ledger.py} test_ledger.py
  python3 test_ledger.py
  touch $out
''
