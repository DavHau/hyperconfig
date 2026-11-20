# The canary's verdict on recorded SearXNG answers (no network), the flake
# check `searxng-canary`: ./fixtures/junk.json is som's production
# instance on 2026-11-20 (Bing filling the top 5 with off-topic pages,
# every other engine but DuckDuckGo blocked; the old canary passed it),
# ./fixtures/good.json the same queries after the fix (DuckDuckGo and
# Google's CSE through the residential proxy). The junk state must FAIL
# with Bing named junk, the good one PASS, with som's thresholds
# (./default.nix) and the candidate gate's (./candidate.nix).
{ pkgs }:
let
  canary = import ./package.nix { inherit pkgs; };
in
pkgs.runCommand "searxng-canary-test" { nativeBuildInputs = [ canary ]; } ''
  set -u
  run() { searxng-canary --url http://unused --replay "$@"; }
  for q in 1 2; do
    args="--queries 2 --min-relevant $q --min-engines 2 --max-junk 0"
    if run ${./fixtures/junk.json} $args >junk.out; then
      cat junk.out
      echo "FAIL: the junk state passed ($args)"
      exit 1
    fi
    grep -q "junk: \['bing'\]" junk.out || { cat junk.out; echo "FAIL: bing not named junk"; exit 1; }
    run ${./fixtures/good.json} $args >good.out || {
      cat good.out
      echo "FAIL: the good state failed ($args)"
      exit 1
    }
  done
  # som's timer: one query per run (--rotate picks it by the clock; here
  # --start), each of the recorded ones alone
  for slot in 0 1; do
    run ${./fixtures/good.json} --queries 1 --start $slot --min-relevant 1 --min-engines 2 \
      --max-junk 0 --prom good.prom >/dev/null || { echo "FAIL: good, query $slot alone"; exit 1; }
    if run ${./fixtures/junk.json} --queries 1 --start $slot --min-relevant 1 --min-engines 2 \
      --max-junk 0 --prom junk.prom >/dev/null; then
      echo "FAIL: junk, query $slot alone passed"
      exit 1
    fi
    grep -qx 'searxng_canary_engine_junk{engine="bing"} 1' junk.prom || { cat junk.prom; echo "FAIL: prom"; exit 1; }
  done
  grep -qx 'searxng_canary_engines_relevant 2' good.prom || { cat good.prom; echo "FAIL: prom"; exit 1; }
  grep -qx 'searxng_canary_engines_junk 0' good.prom || { cat good.prom; echo "FAIL: prom"; exit 1; }
  # the candidate gate (one engine on topic is enough over Mullvad), junk still fails
  run ${./fixtures/junk.json} --queries 2 --min-relevant 2 --min-engines 1 --max-junk 0 >/dev/null &&
    { echo "FAIL: junk passed the candidate's thresholds"; exit 1; }
  # a query the recording lacks is an error, not a pass
  printf '{}' >empty.json
  run empty.json --queries 1 --min-relevant 1 --min-engines 1 >/dev/null && { echo "FAIL: empty passed"; exit 1; }
  echo ok >$out
''
