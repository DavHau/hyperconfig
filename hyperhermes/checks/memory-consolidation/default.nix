# Offline check of ../../modules/core/patches/hermes-memory-background-consolidation.patch
# on the patched hermes package: the patch's own pytest file
# (tests/tools/test_memory_background_consolidation.py; the wheel drops
# tests/, so it is taken from the patch) against the installed modules,
# and ../../modules/core/replay-memory-pending.py on staged records (one
# applied, one dropped and kept in memories/.history/dropped/).
# Under memory.background_consolidation "auto" an unattended patch/remove
# applies with a snapshot in memories/.history/; under "stage" it is
# staged for /memory approve. No network, no VM.
{ pkgs, hermesPackage }:
let
  py = "${hermesPackage.hermesVenv}/bin/python3";
  pytestPath = pkgs.python314Packages.makePythonPath [ pkgs.python314Packages.pytest ];
in
pkgs.runCommand "hyperhermes-memory-consolidation-check" { nativeBuildInputs = [ pkgs.patchutils ]; } ''
  export HOME=$TMPDIR/home
  mkdir -p $HOME src && cd src
  filterdiff -p1 -i 'tests/*' ${../../modules/core/patches/hermes-memory-background-consolidation.patch} | patch -p1 -F0
  PYTHONPATH=${pytestPath} ${py} -m pytest -q -p no:cacheprovider \
    tests/tools/test_memory_background_consolidation.py 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]

  # The preStart script: a staged background remove is applied under "auto".
  export HERMES_HOME=$TMPDIR/agent
  mkdir -p $HERMES_HOME/memories $HERMES_HOME/pending/memory
  printf 'memory:\n  background_consolidation: auto\n' > $HERMES_HOME/config.yaml
  ${py} - <<'PY'
  import json
  from tools import write_approval as wa
  from tools.memory_tool import load_on_disk_store
  from tools.skill_provenance import set_current_write_origin
  store = load_on_disk_store()
  store.add("memory", "stale fact")
  store.add("memory", "kept fact, a long standing convention of this agent")
  store.add("memory", "another durable fact about the environment")
  set_current_write_origin("background_review")
  wa.stage_write(wa.MEMORY, {"action": "remove", "target": "memory", "old_text": "stale",
                             "matched_entry": "stale fact"}, summary="s", origin="background_review")
  # Pinned to an entry that is gone: dropped, but kept whole in .history/dropped/.
  rec = wa.stage_write(wa.MEMORY, {"action": "batch", "target": "memory", "operations": [
      {"action": "remove", "old_text": "gone", "matched_entry": "gone entry"},
      {"action": "add", "content": "fact the review wanted"}]}, summary="s", origin="background_review")
  open("dropped-id", "w").write(rec["id"])
  PY
  ${py} ${../../modules/core/replay-memory-pending.py} $HERMES_HOME 2>&1 | tee -a $out
  ls $HERMES_HOME/pending/memory | grep -q . && { echo "FAIL: still pending" | tee -a $out; exit 1; }
  grep -q 'stale fact' $HERMES_HOME/memories/MEMORY.md && { echo "FAIL: not applied" | tee -a $out; exit 1; }
  grep -q 'kept fact' $HERMES_HOME/memories/MEMORY.md
  ls $HERMES_HOME/memories/.history/*-MEMORY.md > /dev/null
  grep -q 'fact the review wanted' "$HERMES_HOME/memories/.history/dropped/$(cat dropped-id).json"
  [ "$(stat -c %a "$HERMES_HOME/memories/.history/dropped/$(cat dropped-id).json")" = 600 ]
  echo "ok   replay-memory-pending applied the staged remove, kept the dropped record" | tee -a $out
''
