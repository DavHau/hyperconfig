# nixpkgs-bump-workspace: creates and removes the nightly bump's jj
# workspace (../nixpkgs-bump/SKILL.md steps 1 and 6), so the run never
# parses jj's output to decide whether it has one.
#
#   nixpkgs-bump-workspace [--repo DIR] create [NAME]
#   nixpkgs-bump-workspace [--repo DIR] remove NAME
#
# DIR (default @repo@) is the repository, never worked in; the workspace
# is DIR's sibling NAME (default hyperconfig-nixpkgs-bump-<UTC date>; it
# must start with hyperconfig-nixpkgs-bump-). --repo is for
# ./workspace-test.nix.
#
# create: the overlap rule first: any hyperconfig-nixpkgs-bump-* beside
# DIR, as a directory, a jj workspace or a git worktree, means an earlier
# run failed or is still going: exit 1, nothing touched; if listing them
# fails, exit 1 too. Then fetch, `mkdir` (no -p), and the workspace. The
# mkdir is a lock only against a parallel run with the same NAME (with
# the default, one started on the same UTC date); a run with another
# name is kept out by the overlap rule alone. Its stdout is exactly the
# workspace's path; everything else is on stderr. Exit 0 only once the facts hold: jj lists the workspace, its
# @ is an empty change on top of main@origin, the tree is checked out,
# and git lists the worktree. Any failure after the mkdir removes what
# this call created (empty: no bump work yet) and exits 1, so one odd
# night cannot block the next ones.
#
# Why `add` and then `jj new` in the workspace: `workspace add` run in
# the repository snapshots and updates the repository's own working copy
# (stray files there would be committed); with --ignore-working-copy jj
# >= 0.46 registers the workspace and its git worktree but refuses to
# check it out ("This command must be able to update the working copy",
# exit 1). That exit is not trusted either way; `jj new main@origin`,
# run in the new workspace (which has nothing to snapshot), checks the
# tree out, and the facts above decide.
#
# remove: first refuses (exit 1, nothing touched) unless every non-empty
# commit in ::NAME@ is already in ::main@origin, after snapshotting the
# workspace's working copy, so finished but unpushed bump work is never
# deleted; a failing jj counts as a refusal. Then forgets the workspace
# (jj also drops its git worktree), removes its directory (a symlink
# there: only the link) and @logDir@/NAME.old-rev, prunes git's worktree
# entries, and exits 0 only if none of them is left (a failing listing
# counts as left).

repo=@repo@
logDir=@logDir@
prefix=hyperconfig-nixpkgs-bump-

say() { echo "nixpkgs-bump-workspace: $*" >&2; }
die() {
  say "FAIL: $*"
  exit 1
}
usage() {
  echo "usage: nixpkgs-bump-workspace [--repo DIR] create [NAME] | remove NAME" >&2
  exit 2
}

if [ "${1:-}" = --repo ]; then
  repo=${2:?--repo needs a directory}
  shift 2
fi
cmd=${1:-}
[ $# -ge 1 ] && shift
[ -d "$repo/.jj" ] || die "no jj repository at $repo"
repo=$(cd "$repo" && pwd -P)
parent=$(dirname "$repo")
[ -d "$repo/.git" ] || die "$repo is not colocated (no .git directory)"

jjr() { jj -R "$repo" --ignore-working-copy "$@"; }
ws_names() { jjr workspace list -T 'name ++ "\n"'; }
# git's worktree paths, one per line
wt_paths() { git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p'; }
# grep that is quiet about no match (1) but not about an error (2)
filter() { grep "$@" || [ $? = 1 ]; }

check_name() {
  case "$1" in
    "$prefix"*) ;;
    *) die "not a bump workspace name ($prefix*): $1" ;;
  esac
  case "$1" in
    */* | . | ..) die "a name, not a path: $1" ;;
  esac
  # Only plain characters: the name is also put into jj revsets.
  case "$1" in
    *[!A-Za-z0-9._-]*) die "only [A-Za-z0-9._-] in a workspace name: $1" ;;
  esac
}

# Everything left of workspace $1, one line each; empty when none is.
leftovers() {
  local name=$1
  local names paths
  [ -e "$parent/$name" ] || [ -L "$parent/$name" ] && echo "directory $parent/$name"
  if names=$(ws_names); then
    grep -xF >/dev/null -- "$name" <<<"$names" && echo "jj workspace $name"
  else
    echo "unknown: jj workspace list failed"
  fi
  if paths=$(wt_paths); then
    grep -xF >/dev/null -- "$parent/$name" <<<"$paths" && echo "git worktree $parent/$name"
  else
    echo "unknown: git worktree list failed"
  fi
  [ -e "$repo/.git/worktrees/$name" ] && echo "git worktree entry .git/worktrees/$name"
  [ -e "$logDir/$name.old-rev" ] && echo "$logDir/$name.old-rev"
  true
}

# Refuses unless all of workspace $1's work is in main@origin.
check_pushed() {
  local name=$1 names unpushed
  names=$(ws_names) || die "jj workspace list failed, touching nothing"
  grep -xF >/dev/null -- "$name" <<<"$names" || return 0
  if [ -d "$parent/$name/.jj" ] && [ ! -L "$parent/$name" ]; then
    jj -R "$parent/$name" util snapshot >&2 ||
      die "cannot snapshot $parent/$name, touching nothing"
  fi
  unpushed=$(jjr log --no-graph -r "(::\"$name\"@ ~ ::main@origin) ~ empty()" \
    -T 'commit_id.short() ++ "\n"') || die "jj log of $name@ failed, touching nothing"
  [ -z "$unpushed" ] ||
    die "$name has work not in main@origin, touching nothing: $(echo "$unpushed" | paste -sd ' ' -)"
}

remove() {
  local name=$1
  check_pushed "$name"
  if ws_names | grep -xF >/dev/null "$name"; then
    jjr workspace forget "$name" >&2 || say "jj workspace forget $name failed"
  fi
  if wt_paths | grep -xF >/dev/null "$parent/$name"; then
    git -C "$repo" worktree remove --force "$parent/$name" >&2 || true
  fi
  rm -rf -- "${parent:?}/$name"
  rm -f -- "$logDir/$name.old-rev"
  git -C "$repo" worktree prune >&2 || say "git worktree prune failed"
  local left
  left=$(leftovers "$name")
  [ -z "$left" ] || die "left behind: $(echo "$left" | paste -sd ';' -)"
}

case "$cmd" in
  create)
    [ $# -le 1 ] || usage
    name=${1:-$prefix$(date -u +%F)}
    check_name "$name"
    ws=$parent/$name
    # stdout is the path alone: everything else to stderr
    exec 3>&1 1>&2

    # The overlap rule: any bump workspace, in any form; a listing that
    # fails is a refusal.
    dirs=$(find "$parent" -mindepth 1 -maxdepth 1 -name "$prefix*" -printf 'directory %p\n') ||
      die "find in $parent failed, touching nothing"
    names=$(ws_names) || die "jj workspace list failed, touching nothing"
    paths=$(wt_paths) || die "git worktree list failed, touching nothing"
    other=$(
      echo "$dirs" &&
        filter -F -- "$prefix" <<<"$names" | sed 's/^/jj workspace /' &&
        filter -F -- "$parent/$prefix" <<<"$paths" | sed 's/^/git worktree /'
    ) || die "overlap check failed, touching nothing"
    other=$(echo "$other" | sed '/^$/d')
    [ -z "$other" ] || die "an earlier bump workspace exists (earlier night failed or still running), touching nothing: $(echo "$other" | paste -sd ';' -)"

    jjr git fetch >&2 || die "jj git fetch failed"
    mkdir -- "$ws" || die "mkdir $ws failed: another run got there first, touching nothing"

    # From here on the workspace is this call's: on any failure remove it.
    done=0
    cleanup() {
      [ "$done" = 1 ] && return
      say "removing the workspace this call created: $ws"
      (remove "$name") || say "cleanup incomplete; Dave cleans up"
    }
    trap cleanup EXIT

    base=$(jjr log --no-graph -r main@origin -T commit_id) || die "no main@origin"
    # Expected to exit 1 on jj >= 0.46 (see above); the facts below decide.
    jjr workspace add --colocate -r main@origin "$ws" >&2 || true
    ws_names | grep -xF >/dev/null "$name" || die "jj does not list workspace $name"
    (cd "$ws" && jj new main@origin >&2) || die "jj new main@origin in $ws failed"

    parent_rev=$(jj -R "$ws" log --no-graph -r '@-' -T 'commit_id ++ "\n"')
    [ "$parent_rev" = "$base" ] || die "@- in $ws is '$parent_rev', not main@origin ($base)"
    [ "$(jj -R "$ws" log --no-graph -r @ -T 'if(empty, "empty")')" = empty ] ||
      die "@ in $ws is not empty"
    [ -f "$ws/flake.nix" ] && [ -f "$ws/flake.lock" ] || die "no tree checked out in $ws"
    [ "$(jj -R "$ws" workspace root)" = "$ws" ] || die "jj's root for $ws is not $ws"
    wt_paths | grep -xF >/dev/null "$ws" || die "git lists no worktree at $ws"
    [ "$(git -C "$ws" rev-parse HEAD)" = "$base" ] || die "git HEAD in $ws is not main@origin"

    done=1
    trap - EXIT
    say "ok: $name: @ empty on main@origin ($base)"
    echo "$ws" >&3
    ;;
  remove)
    [ $# = 1 ] || usage
    check_name "$1"
    remove "$1"
    say "ok: removed $1"
    ;;
  *) usage ;;
esac
