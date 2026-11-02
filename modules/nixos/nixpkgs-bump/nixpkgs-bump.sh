# The nixpkgs bump of the fleet flake, nightly or on request; ./default.nix
# says what runs it, as whom, and why each step has this shape. Everything
# comes from the unit's environment:
#   STATE_DIR PUBLIC_DIR REPO_URL BRANCH DELIVER_BRANCH FAILED_BRANCH
#   GIT_NAME GIT_EMAIL MACHINES_CONFIG (JSON: hostSystem,
#   machines.<name>.{attr,build}) MAX_JOBS CORES ROUNDS KEEP_RUNS
#   REQUEST_FILE (optional: its presence marks a requested run)
#   AGENT_UNIT (empty: no hand-off) AGENT_REPO SLOT_PUBLIC_DIR SLOT_REPO
#     (PUBLIC_DIR and AGENT_REPO as the agent's slot sees them)
# NIXPKGS_BUMP_MACHINES (optional, for manual runs): only these machines.

log() { printf 'nixpkgs-bump: %s\n' "$*"; }
die() {
  log "error: $*" >&2
  exit 1
}

for var in STATE_DIR PUBLIC_DIR REPO_URL BRANCH DELIVER_BRANCH FAILED_BRANCH GIT_NAME \
  GIT_EMAIL MACHINES_CONFIG MAX_JOBS CORES ROUNDS KEEP_RUNS; do
  [ -n "${!var:-}" ] || die "$var is not set"
done
AGENT_UNIT=${AGENT_UNIT:-}
REQUEST_FILE=${REQUEST_FILE:-}
SLOT_PUBLIC_DIR=${SLOT_PUBLIC_DIR:-$PUBLIC_DIR}

# Only this run's own git configuration: no /etc/gitconfig (its lfs filter
# would run on attributes the agent commits), no ~/.gitconfig.
export GIT_CONFIG_NOSYSTEM=1
export HOME=$STATE_DIR
nix_flags=(
  --extra-experimental-features "nix-command flakes"
  --option accept-flake-config false
  --max-jobs "$MAX_JOBS"
  --cores "$CORES"
)
g() { git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" "$@"; }

bare=$STATE_DIR/hyperconfig.git
work=$STATE_DIR/work
gcroots=$STATE_DIR/gcroots
handoff_dir=$PUBLIC_DIR/handoff
mkdir -p "$gcroots" "$PUBLIC_DIR/runs" "$handoff_dir"

exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another run holds $STATE_DIR/lock"

# A request made before this run is what this run answers; one made while it
# runs (the agent's own, during a hand-off, included) is answered by it too
# and dropped at the end, so no run ever starts the next.
trigger=timer
if [ -n "$REQUEST_FILE" ] && { [ -e "$REQUEST_FILE" ] || [ -L "$REQUEST_FILE" ]; }; then
  trigger=request
  rm -f "$REQUEST_FILE"
fi

run_id=$(date -u +%Y%m%dT%H%M%SZ)
run_dir=$PUBLIC_DIR/runs/$run_id
mkdir -p "$run_dir"
exec > >(tee -a "$run_dir/pipeline.log") 2>&1
started=$(date -u +%FT%TZ)
base="" bump="" old_rev="" new_rev="" round=0 failed="" delivered="" commit="" fixes=""

# The status the agent reads (PUBLIC_DIR is read-only in its slot).
status() {
  jq -n '$ARGS.named | .failed |= (split(" ") | map(select(. != ""))) | .fixes |= (split("\n") | map(select(. != "")))' \
    --arg state "$1" --arg run "$run_id" --arg trigger "$trigger" \
    --arg started "$started" --arg updated "$(date -u +%FT%TZ)" \
    --arg logs "$SLOT_PUBLIC_DIR/runs/$run_id" --arg upstream "$base" --arg bump "$bump" \
    --arg nixpkgs_old "$old_rev" --arg nixpkgs_new "$new_rev" --arg round "$round" \
    --arg rounds "$ROUNDS" --arg failed "$failed" --arg delivered "$delivered" \
    --arg commit "$commit" --arg fixes "$fixes" >"$PUBLIC_DIR/status.json.new"
  mv -f "$PUBLIC_DIR/status.json.new" "$PUBLIC_DIR/status.json"
}
final=""
finish() {
  local rc=$?
  [ -n "$REQUEST_FILE" ] && rm -f "$REQUEST_FILE"
  if [ -z "$final" ]; then
    log "aborted (exit $rc), see $run_dir/pipeline.log"
    status error
  fi
}
trap finish EXIT
status running
log "run $run_id ($trigger), logs in $run_dir"

# --- 1. the delivery repo, and upstream's branch in it ---------------------
[ -d "$bare" ] || git init --quiet --bare "$bare"
git -C "$bare" fetch --quiet --no-tags "$REPO_URL" "+refs/heads/$BRANCH:refs/upstream/$BRANCH"
base=$(git -C "$bare" rev-parse --verify "refs/upstream/$BRANCH^{commit}")
log "upstream $BRANCH is $base"

# --- 2. a fresh work tree at upstream, nixpkgs updated ---------------------
git -C "$bare" worktree remove --force "$work" 2>/dev/null || rm -rf "$work"
git -C "$bare" worktree prune
git -C "$bare" worktree add --quiet --detach "$work" "$base"
cd "$work" || die "no work tree at $work"

lock_rev() { jq -r '(.nodes.root.inputs.nixpkgs) as $n | .nodes[$n].locked.rev // "?"' "$@"; }
old_rev=$(lock_rev flake.lock)
nix "${nix_flags[@]}" flake update nixpkgs || die "nix flake update nixpkgs failed"
if git diff --quiet -- flake.lock; then
  log "nixpkgs unchanged ($old_rev) on upstream $BRANCH: nothing to do"
  final=unchanged
  status unchanged
  exit 0
fi
new_rev=$(lock_rev flake.lock)
g commit --quiet -m "flake.lock: update nixpkgs" -m "nixpkgs $old_rev -> $new_rev" -- flake.lock
bump=$(git rev-parse HEAD)
log "nixpkgs $old_rev -> $new_rev, commit $bump"
status running

# --- 3. evaluate and build every machine, one after the other --------------
# A machine builds if it is for this host's system (others only evaluate),
# unless MACHINES_CONFIG says otherwise; its attribute defaults to the
# toplevel. Every round's outputs are gc roots in its own directory until
# the run ends, so a GC in between cannot take them.
machine_list() {
  if [ -n "${NIXPKGS_BUMP_MACHINES:-}" ]; then
    tr ' ' '\n' <<<"$NIXPKGS_BUMP_MACHINES"
  else
    nix "${nix_flags[@]}" eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]'
  fi
}

verify() {
  local dir=$1 m attr want system ok host_system
  host_system=$(jq -r .hostSystem "$MACHINES_CONFIG")
  mkdir -p "$dir/roots"
  : >"$dir/failed"
  : >"$dir/outputs"
  if ! machine_list >"$dir/machines" 2>"$dir/flake.log"; then
    log "the flake's machine list does not evaluate, see $dir/flake.log"
    echo flake >"$dir/failed"
    return 1
  fi
  while read -r m; do
    [ -n "$m" ] || continue
    attr=$(jq -r --arg m "$m" '.machines[$m].attr // "config.system.build.toplevel"' "$MACHINES_CONFIG")
    want=$(jq -r --arg m "$m" '.machines[$m].build // "auto"' "$MACHINES_CONFIG")
    ok=1
    echo "# nixosConfigurations.$m.$attr (build: $want), round $round of run $run_id" >"$dir/$m.log"
    if ! system=$(nix "${nix_flags[@]}" eval --raw ".#nixosConfigurations.$m.pkgs.stdenv.hostPlatform.system" </dev/null 2>>"$dir/$m.log"); then
      ok=0
    elif [ "$want" = true ] || { [ "$want" = auto ] && [ "$system" = "$host_system" ]; }; then
      log "$m ($system): building $attr"
      nix "${nix_flags[@]}" build --print-build-logs --print-out-paths --out-link "$dir/roots/$m" \
        ".#nixosConfigurations.$m.$attr" </dev/null >>"$dir/outputs" 2>>"$dir/$m.log" || ok=0
    else
      log "$m ($system): evaluating $attr"
      nix "${nix_flags[@]}" eval --raw ".#nixosConfigurations.$m.$attr.drvPath" </dev/null >/dev/null 2>>"$dir/$m.log" || ok=0
    fi
    if [ "$ok" = 1 ]; then
      log "$m: ok"
    else
      log "$m: FAILED, see $dir/$m.log"
      echo "$m" >>"$dir/failed"
    fi
  done <"$dir/machines"
  failed=$(tr '\n' ' ' <"$dir/failed")
  [ ! -s "$dir/failed" ]
}

# --- 4. the agent's hand-off and the safe fetch back -----------------------
handoff() {
  local prev=$1 head m
  head=$(git rev-parse HEAD)
  find "$handoff_dir" -mindepth 1 -delete
  mkdir "$handoff_dir/logs"
  git bundle create --quiet "$handoff_dir/repo.bundle" HEAD
  echo "$head" >"$handoff_dir/base"
  echo "$run_id" >"$handoff_dir/run"
  echo "$round" >"$handoff_dir/round"
  while read -r m; do
    cp "$prev/$m.log" "$handoff_dir/logs/$m.log"
  done <"$prev/failed"
  {
    echo "The nixpkgs bump of hyperconfig, run $run_id ($trigger), fails; this is round $round of $ROUNDS."
    echo "You were started by that run: do not request another bump."
    echo
    echo "nixpkgs moved $old_rev -> $new_rev in commit $bump."
    echo "Your clone is $SLOT_REPO, on branch nixpkgs-bump at $head; commit your fixes there."
    echo "Failed (eval or build) on the host, with their logs:"
    while read -r m; do echo "- $m: $SLOT_PUBLIC_DIR/handoff/logs/$m.log"; done <"$prev/failed"
    echo
    echo "Follow the nixpkgs-bump skill. When you are done, every failure above is fixed by"
    echo "commits on nixpkgs-bump, or you explain why one cannot be fixed within its rules."
  } >"$handoff_dir/prompt.md"
  chmod -R a+rX "$handoff_dir"

  status agent-fixing
  log "round $round: handing ${head:0:12} to $AGENT_UNIT"
  if systemctl start "$AGENT_UNIT"; then
    log "round $round: $AGENT_UNIT finished"
  else
    log "round $round: $AGENT_UNIT failed or timed out; taking what it committed"
  fi
  fetch_back "$head"
  local rc=$?
  status running
  return $rc
}

# The agent's repo is written by its slot: nothing in it is trusted. No git
# runs in it. Its branch tip is read as text, its object files are copied
# into a quarantine repo of ours (no links, no special files, no alternates),
# and only there git checks that the tip is a commit that fast-forwards ours,
# with every object present, and that it keeps to the rules the pipeline can
# check mechanically.
fetch_back() {
  local head=$1 src=$AGENT_REPO/.git ref=refs/heads/nixpkgs-bump tip="" q d changed
  if [ ! -d "$src" ] || [ -L "$src" ] || [ -L "$AGENT_REPO" ]; then
    log "round $round: no agent repo at $AGENT_REPO"
    return 1
  fi
  if [ -f "$src/$ref" ] && [ ! -L "$src/$ref" ]; then
    tip=$(head -c 128 "$src/$ref" | tr -d '\n')
  elif [ -f "$src/packed-refs" ] && [ ! -L "$src/packed-refs" ]; then
    tip=$(awk -v r="$ref" '$2 == r { print $1; exit }' "$src/packed-refs")
  fi
  if ! [[ $tip =~ ^[0-9a-f]{40}$ ]]; then
    log "round $round: the agent's branch nixpkgs-bump is unreadable"
    return 1
  fi
  if [ "$tip" = "$head" ]; then
    log "round $round: the agent committed nothing"
    return 1
  fi

  q=$run_dir/round-$round/quarantine.git
  rm -rf "$q"
  git init --quiet --bare "$q"
  echo "$bare/objects" >"$q/objects/info/alternates"
  for d in "$src"/objects/[0-9a-f][0-9a-f] "$src/objects/pack"; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    cp -R --no-dereference "$d" "$q/objects/"
  done
  if [ -n "$(find "$q/objects" ! -type f ! -type d -print -quit)" ]; then
    log "round $round: the agent's objects hold links or special files; refused"
    return 1
  fi
  if ! git -C "$q" cat-file -e "$tip^{commit}" 2>/dev/null; then
    log "round $round: the agent's tip $tip is no commit"
    return 1
  fi
  if ! git -C "$q" merge-base --is-ancestor "$head" "$tip"; then
    log "round $round: $tip does not fast-forward $head; refused"
    return 1
  fi
  if ! git -C "$q" rev-list --objects "$head..$tip" >/dev/null; then
    log "round $round: objects of $head..$tip are missing; refused"
    return 1
  fi

  changed=$(git -C "$q" diff --name-only "$head" "$tip")
  if grep -E '^(vars|sops|secrets)/' <<<"$changed"; then
    log "round $round: the agent touched secrets (above); refused"
    return 1
  fi
  if [ "$(git -C "$q" show "$head:flake.lock" | lock_rev)" != "$(git -C "$q" show "$tip:flake.lock" | lock_rev)" ]; then
    log "round $round: the agent moved nixpkgs itself; refused"
    return 1
  fi
  if git -C "$q" diff "$head" "$tip" | grep -E '^\+.*(allowBroken|allowInsecure|permittedInsecurePackages|allowUnsupportedSystem|--impure)'; then
    log "round $round: the agent's diff loosens nixpkgs' checks or goes impure (above); refused"
    return 1
  fi

  # Called in a condition, where errexit is off: every step checks itself.
  git -C "$q" update-ref refs/heads/agent "$tip" || return 1
  git -C "$bare" fetch --quiet --no-tags "$q" "+refs/heads/agent:refs/nixpkgs-bump/$run_id/round-$round" || return 1
  git checkout --quiet --detach "$tip" || return 1
  log "round $round: took the agent's commits:"
  git log --format='  %h %s' "$head..$tip"
}

while :; do
  if verify "$run_dir/round-$round"; then
    result=green
    break
  fi
  if [ -z "$AGENT_UNIT" ] || [ "$round" -ge "$ROUNDS" ]; then
    result=red
    break
  fi
  round=$((round + 1))
  if ! handoff "$run_dir/round-$((round - 1))"; then
    result=red
    break
  fi
done

# --- 5. delivery ------------------------------------------------------------
commit=$(git rev-parse HEAD)
fixes=$(git log --format='%h %s' "$bump..$commit")
if [ "$result" = green ]; then
  delivered=$DELIVER_BRANCH
  git -C "$bare" update-ref "refs/heads/$DELIVER_BRANCH" "$commit"
  git -C "$bare" update-ref "refs/tags/$DELIVER_BRANCH-$(date -u +%F)" "$commit"
  # The last green outputs stay gc roots until the next green run.
  mkdir -p "$gcroots/$run_id"
  while read -r out; do
    nix "${nix_flags[@]}" build --out-link "$gcroots/$run_id/$(basename "$out")" "$out"
  done <"$run_dir/round-$round/outputs"
  find "$gcroots" -mindepth 1 -maxdepth 1 ! -name "$run_id" -exec rm -rf {} +
  note="green after $round agent round(s); logs: $run_dir"
else
  delivered=$FAILED_BRANCH
  git -C "$bare" update-ref "refs/heads/$FAILED_BRANCH" "$commit"
  note="FAILED after $round agent round(s) (${failed% }); logs: $run_dir"
fi
g -C "$bare" notes --ref=nixpkgs-bump add --force -m "nixpkgs-bump $run_id: $note" "$commit"
# Each round's own roots go with the run; logs of the last KEEP_RUNS runs stay.
find "$run_dir" -mindepth 2 -maxdepth 2 -name roots -exec rm -rf {} +
find "$PUBLIC_DIR/runs" -mindepth 1 -maxdepth 1 -type d | sort | head -n "-$KEEP_RUNS" | xargs -r rm -rf

final=$result
status "$result"
if [ "$result" = green ]; then
  log "GREEN: $DELIVER_BRANCH is $commit ($note)"
else
  log "RED: $FAILED_BRANCH is $commit ($note)"
  exit 1
fi
