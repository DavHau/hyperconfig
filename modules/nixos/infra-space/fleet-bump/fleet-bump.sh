# fleet-bump: the deterministic nightly nixpkgs bump (./default.nix says
# where it runs and why). No agent: fetch main, move nixpkgs to the
# channel, build every job of .#fleetJobs.<cadence>, push the result to
# the bump's branch (never main), write the status.
#
# Exit: 0 green (every job ok), 1 red (a job failed), 2 error (the run
# itself failed: fetch, update, a nixpkgs older than main's, eval of the
# job list, push, the wait for the agent's bump), 75 another run holds the
# lock (nothing done, nothing written), 143/130 killed (status: error).
#
# Set by ./default.nix (replaced at build time):
repo=@repo@                 # the forge's repository (push and fetch)
branch=@branch@             # the only ref this script pushes
nixpkgs_url=@nixpkgsUrl@    # flake.nix's nixpkgs.url on the branch
channel=@channel@
state=@stateDir@            # status.json, the mirror, work tree, logs
roots=@rootsDir@            # out-links: GC roots of the candidates
keep=@keep@                 # runs whose roots and logs are kept
wait_for=(@waitFor@)        # units a run waits for to be inactive
wait_max=@waitMax@          # ... for at most this many seconds
max_jobs=@maxJobs@
cores=@cores@

set -uo pipefail
umask 022

usage() { echo "usage: fleet-bump [--cadence nightly|weekly]" >&2; exit 2; }
cadence=nightly
while [ $# -gt 0 ]; do
  case "$1" in
    --cadence) [ $# -ge 2 ] || usage; cadence=$2; shift 2 ;;
    *) usage ;;
  esac
done
# The weekly jobs (cm-pi) report apart: their own status file and branch.
case "$cadence" in
  nightly) status_name=status.json ;;
  weekly) status_name=status-weekly.json; branch=$branch-weekly ;;
  *) echo "fleet-bump: bad cadence $cadence" >&2; exit 2 ;;
esac
# Only auto/<something>, never main, whatever the configuration says
# (./default.nix asserts the same).
case "$branch" in
  auto/?*) ;;
  *) echo "fleet-bump: refusing to push to '$branch' (only auto/*)" >&2; exit 2 ;;
esac

mkdir -p "$state" "$roots"
exec 9>"$state/lock"
if ! flock -n 9; then
  echo "fleet-bump: another run holds $state/lock; nothing done" >&2
  exit 75
fi

nix() { command nix --max-jobs "$max_jobs" --cores "$cores" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "fleet-bump: $*" >&2; }

started=$(now)
mkdir -p "$state/runs"
# one directory per run, named by its start (sorted = chronological)
until run_id=$(date -u +%Y%m%dT%H%M%SZ) && mkdir "$state/runs/$run_id" 2>/dev/null; do sleep 1; done
run_dir=$state/runs/$run_id
mkdir -p "$run_dir/logs"
work=$state/work
mirror=$state/mirror.git
jobs_json=$run_dir/jobs.json
errors_json=$run_dir/errors.json
echo '{}' >"$jobs_json"
echo '{}' >"$errors_json"
old_rev="" new_rev="" main_commit="" candidate="" branch_commit="" error=""

# The status: written whole and renamed, so a reader never sees half of it.
write_status() { # result
  jq -n \
    --arg started "$started" --arg finished "$(now)" \
    --arg channel "$channel" --arg nixpkgs_url "$nixpkgs_url" \
    --arg nixpkgs_rev "$new_rev" --arg old_nixpkgs_rev "$old_rev" \
    --arg result "$1" --arg cadence "$cadence" --arg run "$run_id" \
    --arg main_commit "$main_commit" --arg candidate "$candidate" \
    --arg branch "$branch" --arg branch_commit "$branch_commit" \
    --arg error "$error" \
    --slurpfile jobs "$jobs_json" --slurpfile errors "$errors_json" \
    '{started: $started, finished: $finished, channel: $channel,
      nixpkgs_url: $nixpkgs_url, nixpkgs_rev: $nixpkgs_rev,
      old_nixpkgs_rev: $old_nixpkgs_rev, result: $result,
      jobs: $jobs[0], errors: $errors[0], cadence: $cadence, run: $run,
      main_commit: $main_commit, candidate_commit: $candidate,
      branch: $branch, branch_commit: $branch_commit, error: $error}' \
    >"$run_dir/status.json" || return 1
  cp "$run_dir/status.json" "$state/$status_name.tmp" && mv "$state/$status_name.tmp" "$state/$status_name"
}

# Only the newest $keep runs keep their logs, and the newest $keep runs
# that built anything their roots (an error run never evicts builds).
prune() {
  local d
  find "$roots" -mindepth 1 -maxdepth 1 -type d -empty -delete
  for base in "$state/runs" "$roots"; do
    [ -d "$base" ] || continue
    find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +$((keep + 1)) |
      while read -r d; do rm -rf "${base:?}/$d"; done
  done
}

fail() { # message: the run itself failed
  error=$1
  log "error: $error"
  write_status error
  prune
  exit 2
}

# Killed (the unit's timeout, a stop, ^C): still a status, result error.
# bash runs this once the foreground child (killed with it) has exited.
killed() { # signal exit-code
  trap - TERM INT
  error="killed by SIG$1 (timeout or stop)"
  log "error: $error"
  write_status error
  prune
  exit "$2"
}
trap 'killed TERM 143' TERM
trap 'killed INT 130' INT

# The agent's bump still running (a mass rebuild): wait, so the two never
# build at once (2x the load). Here, not in ExecStartPre: the wait has its
# own bound and leaves the unit's timeout to the builds.
if [ "${#wait_for[@]}" -gt 0 ]; then
  waited=0
  while systemctl is-active -q "${wait_for[@]}"; do
    [ "$waited" -lt "$wait_max" ] ||
      fail "still active after ${waited}s (limit ${wait_max}s): ${wait_for[*]}; not building beside it"
    [ "$waited" -gt 0 ] || log "waiting for ${wait_for[*]}"
    sleep 30 & wait $!
    waited=$((waited + 30))
  done
fi

lock_rev() { jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev // empty' "$work/flake.lock"; }
lock_modified() { jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.lastModified // empty' "$work/flake.lock"; }

# 1. A fresh main, in a work tree made anew each run (a killed run's
#    leftovers are simply replaced).
if [ ! -d "$mirror" ]; then
  git init --quiet --bare "$mirror" || fail "git init $mirror"
fi
git -C "$mirror" fetch --quiet --prune "$repo" '+refs/heads/main:refs/heads/main' \
  >"$run_dir/logs/fetch.log" 2>&1 || fail "fetching main from $repo (see $run_dir/logs/fetch.log)"
main_commit=$(git -C "$mirror" rev-parse refs/heads/main) || fail "no main in $repo"
rm -rf "$work"
git clone --quiet --shared --branch main "$mirror" "$work" >"$run_dir/logs/clone.log" 2>&1 ||
  fail "cloning the work tree"
cd "$work" || fail "no work tree"
old_rev=$(lock_rev)
old_modified=$(lock_modified)
[ -n "$old_rev" ] || fail "flake.lock has no nixpkgs rev"

# 2. nixpkgs to the channel: the url line first (one line, exactly), then
#    the lock.
pattern='^\([[:space:]]*nixpkgs\.url[[:space:]]*=[[:space:]]*"\)[^"]*\(";\)'
[ "$(grep -c "$pattern" flake.nix)" = 1 ] || fail "flake.nix: not exactly one nixpkgs.url line"
url_sed=$(printf '%s' "$nixpkgs_url" | sed 's/[\\|&]/\\&/g')
sed -i "s|$pattern|\1$url_sed\2|" flake.nix
nix flake update nixpkgs >"$run_dir/logs/update.log" 2>&1 ||
  fail "nix flake update nixpkgs (see $run_dir/logs/update.log)"
new_rev=$(lock_rev)
[ -n "$new_rev" ] || fail "the new flake.lock has no nixpkgs rev"
# Never backwards: a channel switch (or a channel reset) can point at a
# nixpkgs older than main's.
new_modified=$(lock_modified)
for m in "$old_modified" "$new_modified"; do
  case "$m" in
    "" | *[!0-9]*) fail "flake.lock: nixpkgs lastModified missing or not a number ('$old_modified', '$new_modified')" ;;
  esac
done
[ "$new_modified" -ge "$old_modified" ] ||
  fail "refusing a downgrade: $channel's nixpkgs ${new_rev:0:12} (lastModified $(date -u -d "@$new_modified" +%FT%TZ)) is older than main's ${old_rev:0:12} ($(date -u -d "@$old_modified" +%FT%TZ))"

# The candidate: the bump as a commit of its own (what gets built), or
# main itself when nothing moved.
git add flake.nix flake.lock
if git diff --cached --quiet; then
  candidate=$main_commit
else
  git commit --quiet -m "flake.lock: nixpkgs ${old_rev:0:8} -> ${new_rev:0:8} ($channel)" ||
    fail "committing the bump"
  candidate=$(git rev-parse HEAD)
fi

# 3. Every job, one after another; a failed one never stops the others.
names=$(nix eval --json ".#fleetJobs.$cadence" --apply builtins.attrNames 2>"$run_dir/logs/eval.log") ||
  fail "evaluating the job list .#fleetJobs.$cadence (see $run_dir/logs/eval.log)"
mapfile -t jobs < <(jq -r '.[]' <<<"$names")
[ "${#jobs[@]}" -gt 0 ] || fail "no jobs in .#fleetJobs.$cadence"
mkdir -p "$roots/$run_id"
red=0
for job in "${jobs[@]}"; do
  case "$job" in *[!A-Za-z0-9_.-]*) fail "bad job name: $job" ;; esac
  joblog=$run_dir/logs/$job.log
  log "building $job"
  if nix build -L --keep-going --out-link "$roots/$run_id/$job" ".#fleetJobs.$cadence.\"$job\"" >"$joblog" 2>&1; then
    verdict=ok
  else
    verdict=fail
    red=1
    # Nix's first own error line (`^error:`; a builder's output carries
    # the `<drv>> ` prefix of -L) and the nine after it, printable ASCII
    # only, each cut to 300 characters (build output is not ours: data
    # only). No such line: the log's last ten lines.
    first=$(grep -n -m 1 '^error:' "$joblog" | cut -d: -f1)
    if [ -n "$first" ]; then
      excerpt() { tail -n +"$first" "$joblog" | head -n 10; }
    else
      excerpt() { tail -n 10 "$joblog"; }
    fi
    lines=$(excerpt | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' |
      LC_ALL=C tr -cd '\11\12\40-\176' | cut -c1-300 | jq -R . | jq -s .)
    jq --arg j "$job" --argjson l "$lines" '.[$j] = $l' "$errors_json" >"$errors_json.tmp" && mv "$errors_json.tmp" "$errors_json"
  fi
  log "$job: $verdict"
  jq --arg j "$job" --arg v "$verdict" '.[$j] = $v' "$jobs_json" >"$jobs_json.tmp" && mv "$jobs_json.tmp" "$jobs_json"
done
result=green
[ "$red" = 0 ] || result=red

# 4. The verdicts as an empty commit on top of the candidate (its tree is
#    the candidate's), pushed to the branch: force, it is this job's alone.
{
  echo "fleet-bump: nixpkgs ${old_rev:0:8} -> ${new_rev:0:8} ($channel): $result"
  echo
  echo "result: $result"
  echo "channel: $channel"
  echo "cadence: $cadence"
  echo "nixpkgs: $old_rev -> $new_rev"
  echo "main: $main_commit"
  echo "candidate: $candidate"
  echo "run: $run_id"
  echo
  jq -r 'to_entries[] | "job \(.key): \(.value)"' "$jobs_json"
  jq -r 'to_entries[] | "\nerrors \(.key):", (.value[] | "    \(.)")' "$errors_json"
  echo
  echo "Fleet-Bump-Status: $(jq -c -n --arg r "$result" --arg n "$new_rev" --arg c "$channel" \
    --arg cand "$candidate" --slurpfile j "$jobs_json" \
    '{result: $r, nixpkgs_rev: $n, channel: $c, candidate_commit: $cand, jobs: $j[0]}')"
} >"$run_dir/message"
git commit --quiet --allow-empty -F "$run_dir/message" || fail "committing the verdicts"
tip=$(git rev-parse HEAD)
git push --quiet --force "$repo" "HEAD:refs/heads/$branch" >"$run_dir/logs/push.log" 2>&1 ||
  fail "pushing $branch (see $run_dir/logs/push.log)"
branch_commit=$tip

write_status "$result"
prune
log "$result; $branch at $branch_commit; status in $state/$status_name"
[ "$result" = green ]
