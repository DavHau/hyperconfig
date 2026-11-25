# nixpkgs-bump-guard: the nightly bump's lock-integrity check, run at the
# bump workspace's root right before the push (../nixpkgs-bump/SKILL.md).
# Exit 0 and a last line `nixpkgs-bump-guard: PASS`: push; anything else:
# fix what it names or push nothing.
#
# It checks the lock only, mechanically, what no reviewer can see by
# reading a diff:
# - the root `nixpkgs` input still follows github:NixOS/nixpkgs/
#   nixpkgs-unstable, and its new rev is on that branch (GitHub's compare:
#   the tip or behind it; a commit from a fork, which GitHub serves under
#   NixOS/nixpkgs too, is on neither history) and descends from
#   main@origin's rev; narHash and lastModified are what `nix flake
#   prefetch` of that rev says;
# - the root `searxng` input (SearXNG at upstream master, moved every
#   night), if it moved: the same on github:searxng/searxng master;
# - either of the two that did not move: its lock node unchanged;
# - no other input changed: every other lock node is main@origin's,
#   byte for byte (a new rev is new source too, and no reviewer can judge
#   a 40-hex rev by reading it), and no node is new, unless a commit
#   message in main@origin..@- has a line `flake.lock: node <node>: <why>`:
#   a fix may move or replace an input, but says so where both reviews
#   read it.
# Code changes are the reviews' business, not this script's.
#
# Advisory: the agent holds the push key and could push without it. It
# catches a lock the run did not mean to write, and a rev an injected
# instruction slipped in.
#
#   nixpkgs-bump-guard

[ $# = 0 ] || {
  echo "usage: nixpkgs-bump-guard (at the bump workspace's root)" >&2
  exit 2
}

failed=0
fail() {
  echo "nixpkgs-bump-guard: FAIL: $*" >&2
  failed=1
}
die() {
  fail "$*"
  echo "nixpkgs-bump-guard: push nothing" >&2
  exit 1
}
ok() { echo "nixpkgs-bump-guard: ok: $*"; }

root=$(jj root 2>/dev/null) || die "not in a jj workspace"
[ "$(cd "$root" && pwd -P)" = "$(pwd -P)" ] || die "run it at the workspace root ($root)"

base=$(jj log --no-graph -r 'main@origin' -T 'commit_id') || die "no main@origin"
head=$(jj log --no-graph -r '@-' -T 'commit_id')
[ -n "$(jj log --no-graph -r 'main@origin & ::@' -T 'commit_id')" ] ||
  die "@ does not descend from main@origin: fetch and rebase first"
[ -z "$(jj log --no-graph -r '(main@origin..@) & conflicts()' -T 'commit_id')" ] ||
  die "conflicted commits between main@origin and @"
# What gets pushed is @- (the skill: `jj bookmark set main -r @-`) and
# below: @ empty on top, every commit below it described.
[ "$(jj log --no-graph -r @ -T 'if(empty, "empty")')" = empty ] ||
  die "@ is not empty: \`jj new\` first, so @- is what gets pushed"
[ "$(jj log --no-graph -r @- -T 'commit_id')" != "$base" ] || die "nothing on top of main@origin"
[ -z "$(jj log --no-graph -r '(main@origin..@-) & description(exact:"")' -T 'commit_id')" ] ||
  die "an undescribed commit between main@origin and @-"
ok "@- on main@origin ($base)"
messages=$(jj log --no-graph -r 'main@origin..@-' -T 'description ++ "\n"')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git show "$base:flake.lock" >"$tmp/old.json" || die "no flake.lock on main@origin"
git show "$head:flake.lock" >"$tmp/new.json" || die "no flake.lock in @"

# --- other inputs: unchanged, no new nodes, unless a commit names them
# (the two moved inputs' own checks follow below)
node_of() { # lock input: the root input's node name; a follows list is refused
  jq -r --arg i "$2" '.nodes.root.inputs[$i] | if . == null then "" elif type == "string" then . else error("not a node") end' \
    "$tmp/$1.json" 2>/dev/null || die "flake.lock: root input $2 is not a plain node"
}
nixpkgs=$(node_of new nixpkgs)
searxng=$(node_of new searxng)
[ -n "$nixpkgs" ] || die "flake.lock: no root nixpkgs input"
[ "$(node_of old searxng)" = "$searxng" ] && [ "$(node_of old nixpkgs)" = "$nixpkgs" ] ||
  die "flake.lock: the root nixpkgs or searxng input points at another node than on main@origin"
node() { jq -cS --arg n "$2" '.nodes[$n]' "$tmp/$1.json"; }
named() { # node: a line `flake.lock: node <node>: <why>` in a commit message
  local line
  while IFS= read -r line; do
    [ "${line#flake.lock: node "$1": }" != "$line" ] && return 0
  done <<<"$messages"
  return 1
}
# root itself: its inputs but nixpkgs and searxng (repointing one at
# another node already in the lock is a change too)
root_inputs() { jq -cS '.nodes.root.inputs | del(.nixpkgs, .searxng)' "$tmp/$1.json"; }
if [ "$(root_inputs old)" != "$(root_inputs new)" ] && ! named root; then
  fail "flake.lock: the root's inputs changed and no commit message has a line 'flake.lock: node root: <why>'"
fi
while IFS= read -r n; do
  case "$n" in root | "$nixpkgs" | "$searxng") continue ;; esac
  [ "$(node old "$n")" != "$(node new "$n")" ] || continue
  if named "$n"; then
    ok "flake.lock: input node $n changed, explained by a commit message"
  else
    fail "flake.lock: input node $n changed (or is new) and no commit message has a line 'flake.lock: node $n: <why>': $(node old "$n") -> $(node new "$n")"
  fi
done < <(jq -r '.nodes | keys[]' "$tmp/new.json")

# --- a moved github input: on its branch, ahead of the old rev, real narHash
compare() { # owner/repo base head -> GitHub's compare status
  # $GITHUB_TOKEN if set (unauthenticated, GitHub allows 60 calls an
  # hour), as a header on stdin: never in argv, which `ps` shows
  printf '%s\n' ${GITHUB_TOKEN:+"Authorization: Bearer $GITHUB_TOKEN"} |
    curl -fsS --max-time 60 -H 'Accept: application/vnd.github+json' -H @- \
    "https://api.github.com/repos/$1/compare/$2...$3?per_page=1" | jq -r '.status'
}
check_moved() { # input node owner repo ref(the lock's, may be empty) branch
  local input=$1 n=$2 owner=$3 repo=$4 ref=$5 branch=$6 orig old_rev rev hash mod st prefetch
  orig=$(jq -c --arg o "$owner" --arg r "$repo" --arg b "$ref" \
    '{owner: $o, repo: $r, type: "github"} + (if $b == "" then {} else {ref: $b} end)' -n)
  [ "$(jq -cS --arg n "$n" '.nodes[$n].original' "$tmp/new.json")" = "$(jq -cS . <<<"$orig")" ] ||
    { fail "flake.lock: $input no longer follows github:$owner/$repo${ref:+/$ref}"; return; }
  jq -e --arg n "$n" --arg o "$owner" --arg r "$repo" '.nodes[$n].locked as $l
      | $l.type == "github" and $l.owner == $o and $l.repo == $r
      and ($l.rev | test("^[0-9a-f]{40}$")) and ($l.narHash | test("^sha256-[A-Za-z0-9+/]{43}=$"))' \
    "$tmp/new.json" >/dev/null || { fail "flake.lock: $input is not a plain github:$owner/$repo rev"; return; }
  old_rev=$(jq -r --arg o "$(node_of old "$input")" '.nodes[$o].locked.rev // empty' "$tmp/old.json")
  rev=$(jq -r --arg n "$n" '.nodes[$n].locked.rev' "$tmp/new.json")
  if [ "$rev" = "$old_rev" ]; then
    if [ "$(node old "$(node_of old "$input")")" = "$(node new "$n")" ]; then
      ok "$input stays at ${rev:0:8}"
    else
      fail "flake.lock: $input's rev stayed but its lock node changed (narHash, lastModified, ...)"
    fi
    return
  fi
  st=$(compare "$owner/$repo" "$rev" "$branch") || st=unreachable
  case "$st" in
    identical | ahead) ok "$input ${rev:0:8} is on $owner/$repo $branch ($st)" ;;
    *) fail "$input $rev is not on $owner/$repo $branch (compare: $st)" ;;
  esac
  if [ -n "$old_rev" ]; then
    st=$(compare "$owner/$repo" "$old_rev" "$rev") || st=unreachable
    [ "$st" = ahead ] || fail "$input $rev does not descend from main@origin's ${old_rev:0:8} (compare: $st)"
  fi
  hash=$(jq -r --arg n "$n" '.nodes[$n].locked.narHash' "$tmp/new.json")
  mod=$(jq -r --arg n "$n" '.nodes[$n].locked.lastModified' "$tmp/new.json")
  if ! prefetch=$(nix flake prefetch --json "github:$owner/$repo/$rev"); then
    fail "nix flake prefetch github:$owner/$repo/$rev failed"
  elif [ "$(jq -r '.hash' <<<"$prefetch")" != "$hash" ]; then
    fail "flake.lock: $input's narHash is not the prefetched one"
  elif [ "$(jq -r '.locked.lastModified' <<<"$prefetch")" != "$mod" ]; then
    fail "flake.lock: $input's lastModified is not the prefetched one"
  else
    ok "$input ${old_rev:0:8} -> ${rev:0:8}, narHash matches nix flake prefetch"
  fi
}
check_moved nixpkgs "$nixpkgs" NixOS nixpkgs nixpkgs-unstable nixpkgs-unstable
[ -z "$searxng" ] || check_moved searxng "$searxng" searxng searxng "" master

if [ "$failed" != 0 ]; then
  echo "nixpkgs-bump-guard: push nothing" >&2
  exit 1
fi
echo "nixpkgs-bump-guard: PASS"
