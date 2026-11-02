# One hand-off of the nixpkgs bump to its agent (./default.nix), as the
# agent's own account: prepare the agent's slot over ssh (./slot-setup.sh),
# then run one hermes session to completion through the agent's own
# gateway, so it lands in the agent's dashboard. Environment, from the unit:
#   HANDOFF_DIR SLOT_TARGET SLOT_HANDOFF_DIR SLOT_REPO SLOT_SETUP TOOLS
#   NIX_MAX_JOBS NIX_CORES HERMES PROVIDER MODEL MAX_TURNS RUN_BUDGET SKILL

run=$(cat "$HANDOFF_DIR/run")
round=$(cat "$HANDOFF_DIR/round")
echo "nixpkgs-bump-agent: run $run round $round, preparing $SLOT_TARGET"

ssh -o BatchMode=yes -o ControlMaster=no -o ControlPath=none "$SLOT_TARGET" \
  bash -s -- "$TOOLS" "$NIX_MAX_JOBS" "$NIX_CORES" "$SLOT_HANDOFF_DIR" "$SLOT_REPO" <"$SLOT_SETUP"

echo "nixpkgs-bump-agent: starting the session"
exec "$HERMES" chat --query-file "$HANDOFF_DIR/prompt.md" --quiet --yolo \
  --provider "$PROVIDER" --model "$MODEL" --max-turns "$MAX_TURNS" --run-budget "$RUN_BUDGET" \
  --skills "$SKILL" --continue "nixpkgs-bump $run round $round" --create-if-missing
