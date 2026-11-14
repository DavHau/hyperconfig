# nixpkgs-bump-searxng: the nightly bump's steps for web_search's SearXNG
# (the root flake input `searxng`, upstream master, flake = false; the
# skill's steps 2a-2c, ../nixpkgs-bump/SKILL.md). Run at the bump
# workspace's root, after `flake update nixpkgs`:
#
#   nixpkgs-bump-searxng pick
#     First records master's tip as we see it now in @tips@ (one JSON
#     line per new tip: {date, epoch, tip}; our clock, never upstream's
#     dates, which the committer sets). Then moves the `searxng` node to
#     the newest recorded tip first seen at least @minAgeHours@ h ago (a
#     newer push waits for later nights, so a bad push upstream has time
#     to be noticed and reverted), if it is still on master (one a
#     force-push dropped gives way to the next older aged tip) and ahead
#     of main@origin's pin. Until the record holds a tip that old (the
#     first @minAgeHours@ h after seeding it) nothing can be picked: STAYS.
#     Writes the diff between the two prefetched sources (no URLs;
#     ./searxng-diff.sh: no repository, so nothing in the sources hides a
#     file) to @logDir@/<ws>.searxng-diff for the review, and in parts
#     (.part-NN) of one file-tool read each. Code lines (generated data,
#     minified assets and translations excluded by extension, their diff
#     shown after the code, capped) over @maxDiffLines@ or code bytes over
#     @maxDiffBytes@, a searx/data diff too big to show whole, or a symlink
#     in the new tree that escapes the counted diff: the pin goes back, a
#     decision for Dave is filed. The pick file holds old, new, the diff
#     file's hash and the parts' (count, hash), which review and the guard
#     check. When the aged tip holds, the pick walks back over master's
#     first-parent commits between the pin and that tip (GitHub's
#     compare, oldest first), newest first, at most @maxSteps@ diffs, and
#     takes the newest one that passes: the pin advances up to the
#     commit that blocks, which a decision names (the walk's candidates
#     are ancestors of an aged tip, so the age gate holds for them; the
#     guard checks that online). Last line:
#       PICKED <old8>..<new8> <n> lines   review it (step 2b)
#       STAYS                             nothing to review or test
#       HELD-BACK                         too big or unreviewable; pin back
#                                         to main@origin's
#   nixpkgs-bump-searxng review approve|reject [<why>]
#     Records the review subagent's verdict on exactly that diff
#     (@logDir@/<ws>.searxng-review). reject puts the pin back (HELD-BACK).
#   nixpkgs-bump-searxng canary
#     Builds som's SearXNG package from the workspace and has som run it
#     in its sandbox (../../searxng-canary/candidate.nix, through
#     /run/searxng-candidate/socket: own uid, Mullvad egress only, no
#     secrets), with the search canary. Needs an approve for a moved pin.
#     On a failed canary with a moved pin it puts the pin back and checks
#     again, so a bad upstream commit only holds SearXNG back, never the
#     nixpkgs bump. Last line and exit:
#       PASS       0  the lock as it is passed
#       HELD-BACK  0  searxng back at main@origin's pin, which passed
#       NO-SIGNAL  0  searxng back (if it moved); main@origin's own lock
#                     fails too: the egress or the sites, not the bump
#       FAIL       1  the new nixpkgs breaks SearXNG (main@origin's lock
#                     passes, the bump's fails with either pin), or the
#                     check could not run: a failed night
#     It writes `<verdict> searxng=<rev> nixpkgs=<rev>` to
#     @logDir@/<ws>.searxng-canary; the guard lets a moved searxng through
#     only with a PASS for exactly the lock it checks.
#
# Every outcome that holds SearXNG back is one line per night in
# @logDir@/searxng-history; the third night in a row HELD-BACK or
# STAYS-FORCE-PUSH (upstream force-pushed away the aged tip) prints a
# loud SEARXNG-STUCK line (for the report) and files a decision (our
# patches probably need rebasing onto master).

say() { echo "nixpkgs-bump-searxng: $*" >&2; }
die() {
  say "FAIL: $*"
  echo "nixpkgs-bump-searxng: FAIL"
  exit 1
}
usage() {
  echo "usage: nixpkgs-bump-searxng pick | review approve|reject [<why>] | canary (at the bump workspace's root)" >&2
  exit 2
}
[ $# -ge 1 ] || usage
cmd=$1
shift

ws=$(pwd -P)
name=$(basename "$ws")
case "$name" in
  hyperconfig-nixpkgs-bump-*) ;;
  *) die "not in a bump workspace (hyperconfig-nixpkgs-bump-*): $ws" ;;
esac
root=$(jj root 2>/dev/null) || die "no jj workspace at $ws"
[ "$(cd "$root" && pwd -P)" = "$ws" ] || die "run it at the workspace root ($root), not $ws"
[ -f flake.lock ] || die "no flake.lock here"

logDir=@logDir@
mkdir -p "$logDir"
pickFile=$logDir/$name.searxng-pick
diffFile=$logDir/$name.searxng-diff
reviewFile=$logDir/$name.searxng-review
canaryFile=$logDir/$name.searxng-canary
history=$logDir/searxng-history
tips=@tips@

tmp=$(mktemp -d)
restore_lock=
# A check interrupted while main@origin's lock is in place (the baseline)
# puts the bump's lock back.
trap '[ -z "$restore_lock" ] || cat "$restore_lock" >flake.lock; rm -rf "$tmp"' EXIT

git show "$(jj log --no-graph -r main@origin -T commit_id):flake.lock" >"$tmp/old.json" ||
  die "no flake.lock on main@origin"
node=$(jq -r '.nodes.root.inputs.searxng | strings' "$tmp/old.json")
[ -n "$node" ] || die "main@origin's flake.lock has no root searxng input"
[ "$(jq -r '.nodes.root.inputs.searxng | strings' flake.lock)" = "$node" ] ||
  die "the workspace's flake.lock names another searxng node"
rev() { jq -r --arg n "$node" '.nodes[$n].locked.rev' "$1"; }
nixpkgs_rev() { jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev' "$1"; }
old=$(rev "$tmp/old.json")

revert() {
  jq --arg n "$node" --slurpfile old "$tmp/old.json" '.nodes[$n] = $old[0].nodes[$n]' \
    flake.lock >"$tmp/lock" || die "could not revert the searxng node"
  cat "$tmp/lock" >flake.lock
}

# One JSON line for the decision registry (its inbox; the registry's
# curation takes it in), or a pending file when the registry is not there.
# The same title refiles the open decision with this night's why,
# still_relevant_if and range (decision.py: a refile updates them).
decide() { # title why recommendation still-relevant-if range option...
  local title=$1 why=$2 rec=$3 still=$4 range=$5 inbox=@decisionInbox@ line
  shift 5
  line=$(jq -cn --arg t "$title" --arg w "$why" --arg r "$rec" --arg s "$still" \
    --arg g "$range" --arg d "$(date -u +%F)" --arg src "nixpkgs-bump ($name)" \
    '{title: $t, why: $w, options: $ARGS.positional, recommendation: $r,
      source: $src, date: $d, still_relevant_if: $s, range: $g}' --args "$@")
  if [ -d "$(dirname "$inbox")" ] && echo "$line" >>"$inbox"; then
    say "decision filed for Dave: $title"
  else
    echo "$line" >>"$logDir/decisions-pending.jsonl"
    say "decision for Dave NOT in the registry (no $(dirname "$inbox")), kept in $logDir/decisions-pending.jsonl: $title"
  fi
}

# This night's SearXNG outcome, one line per workspace (the last wins):
# STAYS, STAYS-FORCE-PUSH, PASS, HELD-BACK or NO-SIGNAL.
record() { # outcome old new
  local line
  line="$name $1 ${2:0:8} ${3:0:8}"
  touch "$history"
  { grep -v "^$name " "$history" || true; echo "$line"; } | tail -n 30 >"$tmp/history"
  cat "$tmp/history" >"$history"
  if [ "$(tail -n 3 "$history" | awk '$2 == "HELD-BACK" || $2 == "STAYS-FORCE-PUSH"' | wc -l)" = 3 ]; then
    echo "nixpkgs-bump-searxng: SEARXNG-STUCK: SearXNG held back 3 nights in a row ($(tail -n 3 "$history" | awk '{print $1 " " $2}' | paste -sd ',' -)); our patches probably need rebasing onto master, or upstream force-pushed away every aged tip. Put this line in the report."
    decide "SearXNG stuck on an old upstream for 3 nights" \
      "The nightly bump held SearXNG back three nights in a row (canary, review, diff size or code the review cannot see, or upstream force-pushed away the tips old enough to take). web_search keeps working on the old pin, but falls behind upstream's engine fixes; usually one of our patches no longer fits master." \
      "a) (have a session) rebase our SearXNG patches onto master and retest" \
      "SearXNG still at ${old:0:8} on main" \
      "${old:0:8}" \
      "a) rebase our patches onto master and run the canary by hand" \
      "b) keep the old pin for now" \
      "c) drop the failing patch"
  fi
}

gh() { # path: GitHub API (JSON) -> stdout
  curl -fsS --max-time 60 -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/searxng/searxng/$1"
}
compare() { gh "compare/$1...$2?per_page=1" | jq -r '.status'; }
# master's tip now, recorded with our own clock if it is new to the record
see_tip() {
  local tip now
  tip=$(gh commits/master | jq -r '.sha // empty') || return 1
  [[ $tip =~ ^[0-9a-f]{40}$ ]] || return 1
  touch "$tips"
  if ! jq -e --arg t "$tip" 'select(.tip == $t)' "$tips" >/dev/null 2>&1; then
    now=$(date +%s)
    jq -cn --arg t "$tip" --argjson e "$now" --arg d "$(date -u -d "@$now" +%FT%TZ)" \
      '{date: $d, epoch: $e, tip: $t}' >>"$tips"
    say "master's tip ${tip:0:8} first seen now (recorded in $tips)"
  else
    say "master's tip ${tip:0:8} already recorded"
  fi
  # bounded: a year of nightly tips
  tail -n 400 "$tips" >"$tmp/tips" && cat "$tmp/tips" >"$tips"
}
# the recorded tips first seen at least minAge ago, newest first (none
# yet: empty)
aged_tips() {
  jq -rs --argjson cut "$(($(date +%s) - @minAgeHours@ * 3600))" \
    'group_by(.tip) | map(min_by(.epoch)) | map(select(.epoch <= $cut))
      | sort_by(.epoch) | reverse | .[].tip' "$tips"
}
prefetch() { nixpkgs-bump-nix flake prefetch --json "github:searxng/searxng/$1"; }
# The review reads the parts, not the diff file: `<count> <sha256>` of
# $diffFile.part-01..NN (the count, then one line `<i> <bytes>
# <sha256>` per part in order: the exact split is bound); fails on a gap
# or a stray part (the guard computes the same).
parts_hash() {
  local n=0 all h i p
  while [ -f "$(printf '%s.part-%02d' "$diffFile" $((n + 1)))" ]; do n=$((n + 1)); done
  all=$(find "$logDir" -maxdepth 1 -name "$name.searxng-diff.part-*" | wc -l)
  [ "$n" -gt 0 ] && [ "$all" = "$n" ] || return 1
  h=$({
    echo "$n"
    for i in $(seq 1 "$n"); do
      p=$(printf '%s.part-%02d' "$diffFile" "$i")
      printf '%s %s %s\n' "$i" "$(wc -c <"$p")" "$(sha256sum <"$p" | cut -c1-64)"
    done
  } | sha256sum | cut -c1-64) || return 1
  echo "$n $h"
}

case "$cmd" in
  pick)
    [ $# = 0 ] || usage
    rm -f "$pickFile" "$diffFile" "$diffFile".part-* "$reviewFile" "$canaryFile"
    revert # start from main@origin's pin, whatever `flake update` did
    see_tip || die "GitHub: no tip for searxng's master"
    aged_tips >"$tmp/aged" || die "could not read $tips"
    if ! [ -s "$tmp/aged" ]; then
      say "no tip of master in $tips first seen @minAgeHours@ h ago or more yet (the record is younger): nothing to pick"
      record STAYS "$old" "$old"
      echo "nixpkgs-bump-searxng: STAYS"
      exit 0
    fi
    # The newest aged tip still on master: a force-push upstream drops
    # tips, then the next older aged one is the candidate (at most 10
    # tries, GitHub's rate limit; never past the pin).
    cand='' dropped=0
    while read -r t; do
      if [ "$t" = "$old" ]; then
        cand=$t
        break
      fi
      status=$(compare "$t" master) || status=unreachable
      case "$status" in
        identical | ahead)
          cand=$t
          break
          ;;
        unreachable)
          say "GitHub: could not compare ${t:0:8} with master; nothing picked tonight"
          break
          ;;
        *)
          say "the aged tip ${t:0:8} is no longer on master (compare: $status), trying the next older one"
          dropped=$((dropped + 1))
          ;;
      esac
    done < <(head -n 10 "$tmp/aged")
    # a night that stays because upstream force-pushed counts towards
    # SEARXNG-STUCK, like a held-back one
    stays=STAYS
    [ "$dropped" = 0 ] || stays=STAYS-FORCE-PUSH
    if [ -z "$cand" ]; then
      say "none of the $dropped newest aged tips is still on master: nothing to pick"
      record "$stays" "$old" "$old"
      echo "nixpkgs-bump-searxng: STAYS"
      exit 0
    fi
    if [ "$cand" = "$old" ]; then
      say "the newest tip seen @minAgeHours@ h ago and still on master is main@origin's pin ${old:0:8}"
      record "$stays" "$old" "$old"
      echo "nixpkgs-bump-searxng: STAYS"
      exit 0
    fi
    status=$(compare "$old" "$cand") || status=unreachable
    if [ "$status" != ahead ]; then
      say "the aged tip ${cand:0:8} is not ahead of the pin ${old:0:8} (compare: $status)"
      record "$stays" "$old" "$old"
      echo "nixpkgs-bump-searxng: STAYS"
      exit 0
    fi
    po=$(prefetch "$old") || die "prefetch of searxng $old failed"
    # try NEW: write the diff of old..NEW; why it holds in $why (empty:
    # the review can take it)
    # (a step of the walk, `try <rev> step`, whose prefetch fails is
    # skipped: it holds with that reason, the walk goes on)
    try() {
      local rc=0 p
      rm -f "$diffFile" "$diffFile".part-*
      if ! p=$(prefetch "$1"); then
        [ "${2:-}" = step ] || die "prefetch of searxng $1 failed"
        why="its prefetch failed (skipped)"
        say "prefetch of searxng ${1:0:8} failed: skipping that commit"
        return 0
      fi
      pn=$p
      nixpkgs-bump-searxng-diff "$(jq -r .storePath <<<"$po")" "$(jq -r .storePath <<<"$pn")" \
        "$diffFile" "$old -> $1" >"$tmp/diffout" || rc=$?
      [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "could not diff the sources"
      read -r lines bytes _ <"$tmp/diffout" || true
      [[ $lines =~ ^[0-9]+$ ]] && [[ $bytes =~ ^[0-9]+$ ]] || die "no size from the diff"
      why=$(sed -n 's/^HOLD //p' "$tmp/diffout" | paste -sd ';' -)
      [ "$rc" = 3 ] && [ -z "$why" ] && why="the diff tool held it back"
      if [ -n "$why" ]; then
        why="the review cannot see all of the new tree: $why"
      elif [ "$lines" -gt @maxDiffLines@ ]; then
        why="$lines lines of code diff, over @maxDiffLines@: too big for the nightly review"
      elif [ "$bytes" -gt @maxDiffBytes@ ]; then
        why="$bytes bytes of code diff, over @maxDiffBytes@: too big for the nightly review"
      fi
    }
    tip=$cand
    try "$tip"
    tip_why=$why new=$tip
    if [ -n "$why" ]; then
      # Step-wise: master's first-parent commits old..tip, newest first
      # after the tip, at most @maxSteps@ diffs; the newest that passes
      # is the pick (it is an ancestor of the aged tip: the age gate's).
      # The blocking commit (the oldest one tried that holds, the one
      # after the pick) is what the decision names.
      say "searxng ${old:0:8}..${tip:0:8} holds ($why); walking back over master's first-parent commits"
      # (compare lists the commits tip has and old has not; first
      # parents from the tip down, until old or the list's end)
      gh "compare/$old...$tip?per_page=250" |
        jq -r --arg old "$old" --arg tip "$tip" '
          (.commits | map({key: .sha, value: (.parents[0].sha // null)}) | from_entries) as $p
          | [$tip] | until(.[-1] == null or .[-1] == $old; . + [$p[.[-1]]])
          | .[1:] | map(select(. != null and . != $old)) | .[]' >"$tmp/steps" 2>/dev/null ||
        : >"$tmp/steps"
      blocker=$tip blocker_why=$why new=
      tries=1
      while read -r c && [ "$tries" -lt @maxSteps@ ]; do
        [[ $c =~ ^[0-9a-f]{40}$ ]] || continue
        tries=$((tries + 1))
        try "$c" step
        if [ -z "$why" ]; then
          # forward from the pin (a first parent may come from a branch)
          if [ "$(compare "$old" "$c" || echo unreachable)" = ahead ]; then
            new=$c
            break
          fi
          why="not ahead of the pin ${old:0:8}"
        fi
        blocker=$c blocker_why=$why
      done <"$tmp/steps"
      if [ -z "$new" ]; then
        # the decision is about old..tip: its diff file must be that one,
        # not the last step's
        try "$tip"
        why="$tip_why (and the $((tries - 1)) first-parent commits before it tried: none passes; the oldest tried, ${blocker:0:8}: $blocker_why)"
        new=$tip
      else
        why=
        say "searxng ${old:0:8}..${new:0:8} passes (the first-parent commit before ${blocker:0:8}, which holds: $blocker_why)"
      fi
    fi
    jq --arg n "$node" --argjson p "$pn" \
      '.nodes[$n].locked = ($p.locked | {lastModified, narHash: $p.hash, owner, repo, rev, type})' \
      flake.lock >"$tmp/lock" || die "could not write the searxng node"
    cat "$tmp/lock" >flake.lock
    if [ -n "$why" ]; then
      revert
      say "searxng ${old:0:8}..${new:0:8} held back: $why"
      decide "SearXNG update held back from the nightly review" \
        "Upstream SearXNG moved ${old:0:8}..${new:0:8} (as of $(date -u +%F)), but $why. The nightly bump only takes upstream code its review has seen, so SearXNG stays on the old pin until someone reviews this update; the diff of ${old:0:8}..${new:0:8} is in $diffFile." \
        "a) (have a session) review the diff with a subagent and take the update" \
        "the pin on main is still ${old:0:8} and master's aged tip ${new:0:8} still holds the nightly review" \
        "${old:0:8}..${new:0:8}" \
        "a) have a session review it and take it" \
        "b) keep the old pin, re-check next week" \
        "c) raise the nightly size limit (only if it was the size)"
      record HELD-BACK "$old" "$new"
      echo "nixpkgs-bump-searxng: HELD-BACK"
      exit 0
    fi
    if [ "$new" != "$tip" ]; then
      # the pin moves, but master's newer commits still wait: Dave sees
      # which commit blocks (refiled each night with the current range)
      decide "SearXNG update held back from the nightly review" \
        "Upstream SearXNG moved ${old:0:8}..${tip:0:8} (as of $(date -u +%F)). Tonight's pick takes it up to ${new:0:8}; the next first-parent commit ${blocker:0:8} holds: $blocker_why. Until someone reviews that one, the nightly bump stops there." \
        "a) (have a session) review ${blocker:0:8} with a subagent and take it" \
        "master's aged tip ${tip:0:8} is still ahead of the pin and ${blocker:0:8} still holds the nightly review" \
        "${new:0:8}..${tip:0:8}" \
        "a) have a session review it and take it" \
        "b) keep stepping nightly, re-check next week" \
        "c) raise the nightly size limit (only if it was the size)"
    fi
    ph=$(parts_hash) || die "the diff's parts $diffFile.part-NN are not 01..NN"
    printf '%s %s %s %s\n' "$old" "$new" "$(sha256sum <"$diffFile" | cut -c1-64)" "$ph" >"$pickFile"
    say "diff for the review: $diffFile, in ${ph%% *} parts $diffFile.part-NN"
    echo "nixpkgs-bump-searxng: PICKED ${old:0:8}..${new:0:8} $lines lines"
    ;;

  review)
    [ $# -ge 1 ] || usage
    verdict=$1
    shift
    [ -r "$pickFile" ] || die "no pick for this workspace (run pick first)"
    read -r p_old new p_hash p_n p_parts <"$pickFile"
    [ "$p_old" = "$old" ] || die "the pick was against ${p_old:0:8}, main@origin's pin is ${old:0:8}: pick again"
    [ "$(rev flake.lock)" = "$new" ] || die "flake.lock's searxng is not the picked ${new:0:8}"
    [ "$(sha256sum <"$diffFile" | cut -c1-64)" = "$p_hash" ] || die "$diffFile changed since the pick"
    [ -n "${p_parts:-}" ] && [ "$(parts_hash || true)" = "$p_n $p_parts" ] ||
      die "the diff's parts $diffFile.part-NN changed since the pick (the review read those)"
    case "$verdict" in
      approve)
        echo "approve searxng=$old..$new diff=$p_hash" >"$reviewFile"
        echo "nixpkgs-bump-searxng: REVIEWED ${old:0:8}..${new:0:8}"
        ;;
      reject)
        echo "reject searxng=$old..$new diff=$p_hash $*" >"$reviewFile"
        revert
        record HELD-BACK "$old" "$new"
        echo "nixpkgs-bump-searxng: HELD-BACK"
        ;;
      *) usage ;;
    esac
    ;;

  canary)
    [ $# = 0 ] || usage
    socket=@socket@
    [ -S "$socket" ] || die "no $socket: the host runs no sandbox for candidates"
    new=$(rev flake.lock)
    if [ "$new" != "$old" ]; then
      [ "$(cat "$reviewFile" 2>/dev/null)" = "approve searxng=$old..$new diff=$(cut -d' ' -f3 "$pickFile" 2>/dev/null)" ] ||
        die "searxng moved to ${new:0:8} without an approved review of ${old:0:8}..${new:0:8} (step 2b)"
    fi

    # One run of what the workspace builds in som's sandbox; 0 = passed.
    check() {
      local r pkg
      r=$(rev flake.lock)
      say "checking searxng ${r:0:8}, nixpkgs $(nixpkgs_rev flake.lock | cut -c1-8)"
      nixpkgs-bump-nix build -L --no-link --print-out-paths \
        .#nixosConfigurations.som.config.services.searx.package >"$tmp/out" 2>"$tmp/build.log" || {
        tail -n 30 "$tmp/build.log" >&2
        say "the build failed (log above)"
        return 1
      }
      pkg=$(head -n 1 "$tmp/out")
      # The host's limit is 15 min per instance.
      printf '%s %s\n' "$pkg" "$r" | socat -t 960 -T 960 - "UNIX-CONNECT:$socket" >"$tmp/reply" 2>&1
      cat "$tmp/reply" >&2
      [ "$(tail -n 1 "$tmp/reply")" = "searxng-candidate: PASS" ]
    }
    verdict() {
      printf '%s searxng=%s nixpkgs=%s\n' "$1" "$(rev flake.lock)" "$(nixpkgs_rev flake.lock)" >"$canaryFile"
      # the night's line is the moved pin's outcome; with an unmoved pin
      # pick's (STAYS, HELD-BACK) or the review's stands
      [ "$new" = "$old" ] || record "$1" "$old" "$new"
      echo "nixpkgs-bump-searxng: $1"
      exit 0
    }
    if check; then
      verdict PASS
    fi
    # The bump's nixpkgs fails with main@origin's searxng: the bump or the
    # egress? main@origin's whole lock decides.
    baseline() {
      cp flake.lock "$tmp/bump.lock"
      restore_lock=$tmp/bump.lock
      cat "$tmp/old.json" >flake.lock
      local rc=0
      check || rc=$?
      cat "$tmp/bump.lock" >flake.lock
      restore_lock=
      if [ "$rc" = 0 ]; then
        die "main@origin's lock passes, the new nixpkgs fails: it breaks SearXNG"
      fi
      say "main@origin's lock fails too: no signal from this egress"
      verdict NO-SIGNAL
    }
    if [ "$new" = "$old" ]; then
      baseline
    fi
    say "searxng ${new:0:8} failed; back to main@origin's ${old:0:8}"
    revert
    if check; then
      verdict HELD-BACK
    fi
    baseline
    ;;

  *) usage ;;
esac
