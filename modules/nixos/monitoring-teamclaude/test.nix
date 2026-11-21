# The TeamClaude usage pipeline's logic, without a VM: som's per-client and
# account exporter (../teamclaude-gateway/usage-metrics.mjs) against
# TeamClaude's own usage store, and the ledger behind the usage pages
# (./ledger.py), plus OAuth exporter, guarded recovery and Grafana queries.
# checks.x86_64-linux.monitoring-teamclaude in flake.nix.
{ pkgs, package, oauthRules }:
pkgs.runCommand "monitoring-teamclaude-test" {
  nativeBuildInputs = [
    pkgs.nodejs
    pkgs.python3
    pkgs.prometheus.cli
  ];
} ''
  mkdir scratch
  node --no-warnings ${../teamclaude-gateway/usage-metrics-test.mjs} \
    ${package}/share/teamclaude/src ${../teamclaude-gateway/usage-metrics.mjs} "$PWD/scratch"
  cp ${./ledger.py} ledger.py
  cp ${./test_ledger.py} test_ledger.py
  python3 test_ledger.py
  cp ${../teamclaude-gateway/oauth-status.mjs} oauth-status.mjs
  cp ${../teamclaude-gateway/oauth-relogin.mjs} oauth-relogin.mjs
  cp ${../teamclaude-gateway/oauth-test.mjs} oauth-test.mjs
  node --no-warnings oauth-test.mjs ${package}/share/teamclaude/src "$PWD/scratch"
  python3 ${./test_oauth_rules.py} ${pkgs.writeText "teamclaude-oauth-rules.json" (builtins.toJSON oauthRules)} queries.json
  promtool test rules queries.json
  touch $out
''
