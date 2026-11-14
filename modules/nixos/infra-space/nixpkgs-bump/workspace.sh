# nixpkgs-bump-workspace: creates and removes the nightly bump's jj
# workspace (../nixpkgs-bump/SKILL.md steps 1 and 6), so the run never
# parses jj's output to decide whether it has one.
#
#   nixpkgs-bump-workspace create [NAME]
#   nixpkgs-bump-workspace remove NAME
#
# The repository is @repo@ (fixed at build time, no flag: ./workspace.nix's
# `repo` is for ./workspace-test.nix), never worked in; the workspace is
# its sibling NAME (default hyperconfig-nixpkgs-bump-<UTC date>; it must
# start with hyperconfig-nixpkgs-bump-).
#
# The caller (the unattended run, which reads upstream text) is not
# trusted to have a sane environment: every jj and git call runs under
# `env -i` with a fresh empty HOME, JJ_CONFIG = ./workspace.nix's pinned
# config (no revset aliases, so `empty()` and the like are jj's own; all
# files tracked on snapshot), git without system or global config, and
# only JJ_USER/JJ_EMAIL passed through. The repository, its .jj, .jj/repo
# and .git must be real directories and .jj/repo/config.toml (legacy
# in-tree config jj would apply) absent.
#
# create: the overlap rule first: any hyperconfig-nixpkgs-bump-* beside
# the repository, as a directory, a jj workspace or a git worktree, means
# an earlier run failed or is still going: exit 1, nothing touched; if
# listing them fails, exit 1 too. Then fetch, `mkdir` (no -p), and the
# workspace. The mkdir is a lock only against a parallel run with the
# same NAME (with the default, one started on the same UTC date); a run
# with another name is kept out by the overlap rule alone. Its stdout is
# exactly the workspace's path; everything else is on stderr. Exit 0 only
# once the facts hold: jj lists the workspace, its @ is an empty change
# on top of main@origin, the tree is checked out, and git lists the
# worktree. Any failure after the mkdir removes what this call created
# (empty: no bump work yet) and exits 1, so one odd night cannot block
# the next ones.
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
# remove goes by path, DIR = the repository's sibling NAME. It first
# refuses (exit 1, nothing touched) unless:
# - jj's workspace NAME, if any, is at DIR, and no other one is;
#   git's .git/worktrees/NAME, if any, is DIR's;
# - DIR, if it exists, is a symlink jj and git do not take for a
#   workspace (only the link goes), an empty directory (a create that
#   died after its mkdir), or workspace NAME's own directory: real .jj
#   (no symlinks, only jj's entries) pointing at the repository, .git a
#   plain file pointing at .git/worktrees/NAME, jj's root for it DIR and
#   its @ the working copy of NAME alone (so a .jj copied or linked from
#   another workspace cannot make the snapshot write into that one);
# - after snapshotting DIR, every non-empty commit in ::NAME@ is in
#   ::main@origin, so finished but unpushed bump work is never deleted.
# A failing jj or git counts as a refusal. Then forgets the workspace
# (jj also drops its git worktree), removes DIR and @logDir@/NAME.old-rev,
# prunes git's worktree entries, and exits 0 only if none of them is left
# (a failing listing counts as left).

repo=@repo@
logDir=@logDir@
prefix=hyperconfig-nixpkgs-bump-

say() { echo "nixpkgs-bump-workspace: $*" >&2; }
die() {
  say "FAIL: $*"
  exit 1
}
usage() {
  echo "usage: nixpkgs-bump-workspace create [NAME] | remove NAME" >&2
  exit 2
}

cmd=${1:-}
[ $# -ge 1 ] && shift

# The pinned environment for every jj and git call (see above): nothing
# of the caller's but the identity jj writes into new commits.
jjHome=$(mktemp -d) || die "mktemp failed"
on_exit() { rm -rf -- "$jjHome"; }
trap on_exit EXIT
identity=()
# Only the commit identity passes through from the caller: it affects
# commit metadata, nothing this helper decides on.
[ -n "${JJ_USER:-}" ] && identity+=("JJ_USER=$JJ_USER")
[ -n "${JJ_EMAIL:-}" ] && identity+=("JJ_EMAIL=$JJ_EMAIL")
pinned() {
  env -i PATH=@path@ HOME="$jjHome" TZ=UTC JJ_CONFIG=@jjConfig@ "${identity[@]}" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 "$@"
}
jj() { pinned jj --no-pager --color=never "$@"; }
git() { pinned git "$@"; }

# A real directory each: symlinks there would point jj or git elsewhere.
for d in "$repo" "$repo/.jj" "$repo/.jj/repo" "$repo/.git"; do
  [ -d "$d" ] && [ ! -L "$d" ] || die "$d is not a real directory (no colocated jj repository at $repo)"
done
# jj migrates these legacy in-tree configs into the (fresh) user config
# dir and applies them: they must not exist.
[ ! -e "$repo/.jj/repo/config.toml" ] && [ ! -L "$repo/.jj/repo/config.toml" ] ||
  die "$repo/.jj/repo/config.toml exists (in-tree repo config), touching nothing"
repo=$(cd "$repo" && pwd -P)
parent=$(dirname "$repo")
case "$parent" in
  *[!A-Za-z0-9._/-]*) die "only [A-Za-z0-9._/-] in the repository's parent: $parent" ;;
esac

jjr() { jj -R "$repo" --ignore-working-copy "$@"; }
# jj's workspaces, one `"NAME" "ROOT"` (JSON strings) per line
ws_list() { jjr workspace list -T 'json(self.name()) ++ " " ++ json(self.root()) ++ "\n"'; }
ws_names() { ws_list | sed -n 's/^"\([^"]*\)" .*/\1/p'; }
# git's worktree paths, one per line
wt_paths() { git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p'; }
# grep that is quiet about no match (1) but not about an error (2)
filter() { grep "$@" || [ $? = 1 ]; }
# $2 (a path in file $1, absolute or relative to $1's directory), resolved
# lexically (symlinks are checked for on their own)
resolve_in() {
  local p=$2
  case "$p" in /*) ;; *) p=$(dirname "$1")/$p ;; esac
  realpath -m -s -- "$p"
}

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
  local name=$1 ws=$parent/$1
  local list paths
  [ -e "$ws" ] || [ -L "$ws" ] && echo "directory $ws"
  if list=$(ws_list); then
    filter -F -- "\"$name\" " <<<"$list" | sed 's/^/jj workspace /'
    filter -F -- " \"$ws\"" <<<"$list" | sed 's/^/jj workspace /'
  else
    echo "unknown: jj workspace list failed"
  fi
  if paths=$(wt_paths); then
    grep -xF >/dev/null -- "$ws" <<<"$paths" && echo "git worktree $ws"
  else
    echo "unknown: git worktree list failed"
  fi
  [ -e "$repo/.git/worktrees/$name" ] && echo "git worktree entry .git/worktrees/$name"
  [ -e "$logDir/$name.old-rev" ] && echo "$logDir/$name.old-rev"
  true
}

# Refuses (exit 1, nothing touched) unless $ws is workspace $name's own
# directory, made by `jj workspace add` and nothing else: its .jj and
# .git real (no symlink anywhere in .jj), only jj's entries in .jj, .jj/repo
# pointing at $repo's, .git at .git/worktrees/$name, jj's root for it $ws
# and its @ the working copy of workspace $name alone.
check_own_dir() {
  local name=$1 ws=$2 e c wcs
  [ -d "$ws/.jj" ] && [ ! -L "$ws/.jj" ] || die "$ws/.jj is not a real directory, touching nothing"
  [ -z "$(find "$ws/.jj" -type l -print -quit)" ] || die "a symlink in $ws/.jj, touching nothing"
  [ -z "$(find "$ws/.jj" ! -type f ! -type d -print -quit)" ] || die "an odd file in $ws/.jj, touching nothing"
  for e in "$ws"/.jj/* "$ws"/.jj/.*; do
    [ -e "$e" ] || continue
    case "${e##*/}" in
      . | .. | .gitignore | repo | working_copy | workspace-config-id) ;;
      *) die "unknown $e (jj writes no such file), touching nothing" ;;
    esac
  done
  [ -f "$ws/.jj/repo" ] || die "$ws/.jj/repo is not a file, touching nothing"
  [ "$(resolve_in "$ws/.jj/repo" "$(cat -- "$ws/.jj/repo")")" = "$repo/.jj/repo" ] ||
    die "$ws/.jj/repo does not point at $repo/.jj/repo, touching nothing"
  if [ -e "$ws/.git" ] || [ -L "$ws/.git" ]; then
    [ -f "$ws/.git" ] && [ ! -L "$ws/.git" ] || die "$ws/.git is not a plain file, touching nothing"
    c=$(sed -n '1s/^gitdir: //p' "$ws/.git")
    [ -n "$c" ] && [ "$(resolve_in "$ws/.git" "$c")" = "$repo/.git/worktrees/$name" ] ||
      die "$ws/.git does not point at $repo/.git/worktrees/$name, touching nothing"
  fi
  [ "$(jj -R "$ws" --ignore-working-copy workspace root)" = "$ws" ] ||
    die "jj's root for $ws is not $ws, touching nothing"
  wcs=$(jj -R "$ws" --ignore-working-copy log --no-graph -r @ \
    -T 'self.working_copies().map(|w| json(w.name())).join(" ")') ||
    die "jj log of @ in $ws failed, touching nothing"
  [ "$wcs" = "\"$name\"" ] ||
    die "$ws's @ is the working copy of $wcs, not of $name alone, touching nothing"
}

# Refuses (exit 1, nothing touched) unless $parent/$1 is bump workspace
# $1's, by path, and all of its work is in main@origin.
check_remove() {
  local name=$1 ws=$parent/$1 list paths byname bypath admin unpushed e
  list=$(ws_list) || die "jj workspace list failed, touching nothing"
  paths=$(wt_paths) || die "git worktree list failed, touching nothing"
  byname=$(filter -F -- "\"$name\" " <<<"$list") || die "grep failed"
  bypath=$(filter -F -- " \"$ws\"" <<<"$list") || die "grep failed"
  [ -z "$byname" ] || [ "$byname" = "\"$name\" \"$ws\"" ] ||
    die "jj workspace $name is not at $ws ($byname), touching nothing"
  [ -z "$bypath" ] || [ "$bypath" = "\"$name\" \"$ws\"" ] ||
    die "another jj workspace is at $ws ($bypath), touching nothing"
  admin=$repo/.git/worktrees/$name
  if [ -e "$admin/gitdir" ]; then
    [ "$(resolve_in "$admin/gitdir" "$(cat -- "$admin/gitdir")")" = "$ws/.git" ] ||
      die "git worktree entry $admin is not $ws's, touching nothing"
  fi

  if [ -L "$ws" ]; then
    # only the link goes; one jj or git took for the workspace is refused
    [ -z "$byname" ] || die "$ws is a symlink, but jj has workspace $name there, touching nothing"
    ! grep -xF >/dev/null -- "$ws" <<<"$paths" ||
      die "$ws is a symlink, but git has a worktree there, touching nothing"
  elif [ -e "$ws" ]; then
    [ -d "$ws" ] || die "$ws is not a directory, touching nothing"
    if [ -n "$byname" ]; then
      check_own_dir "$name" "$ws"
      jj -R "$ws" util snapshot >&2 || die "cannot snapshot $ws, touching nothing"
    else
      # not a jj workspace: only an empty directory (a create that died
      # right after its mkdir) goes
      for e in "$ws"/* "$ws"/.*; do
        case "${e##*/}" in . | ..) continue ;; esac
        [ -e "$e" ] || [ -L "$e" ] || continue
        die "$ws is no jj workspace $name and not empty ($e), touching nothing"
      done
    fi
  fi

  [ -n "$byname" ] || return 0
  # builtin revset functions: the pinned config has no aliases
  unpushed=$(jjr log --no-graph -r "(::\"$name\"@ ~ ::main@origin) ~ empty()" \
    -T 'commit_id.short() ++ "\n"') || die "jj log of $name@ failed, touching nothing"
  [ -z "$unpushed" ] ||
    die "$name has work not in main@origin, touching nothing: $(echo "$unpushed" | paste -sd ' ' -)"
}

remove() {
  local name=$1 ws=$parent/$1
  check_remove "$name"
  if ws_list | grep -xF >/dev/null -- "\"$name\" \"$ws\""; then
    jjr workspace forget "$name" >&2 || say "jj workspace forget $name failed"
  fi
  if wt_paths | grep -xF >/dev/null -- "$ws"; then
    git -C "$repo" worktree remove --force "$ws" >&2 || true
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
    on_exit() {
      if [ "$done" != 1 ]; then
        say "removing the workspace this call created: $ws"
        (remove "$name") || say "cleanup incomplete; Dave cleans up"
      fi
      rm -rf -- "$jjHome"
    }

    base=$(jjr log --no-graph -r main@origin -T commit_id) || die "no main@origin"
    # Expected to exit 1 on jj >= 0.46 (see above); the facts below decide.
    jjr workspace add --colocate -r main@origin "$ws" >&2 || true
    ws_names | grep -xF >/dev/null "$name" || die "jj does not list workspace $name"
    jj -R "$ws" new main@origin >&2 || die "jj new main@origin in $ws failed"

    parent_rev=$(jj -R "$ws" log --no-graph -r '@-' -T 'commit_id ++ "\n"')
    [ "$parent_rev" = "$base" ] || die "@- in $ws is '$parent_rev', not main@origin ($base)"
    [ "$(jj -R "$ws" log --no-graph -r @ -T 'if(empty, "empty")')" = empty ] ||
      die "@ in $ws is not empty"
    [ -f "$ws/flake.nix" ] && [ -f "$ws/flake.lock" ] || die "no tree checked out in $ws"
    [ "$(jj -R "$ws" workspace root)" = "$ws" ] || die "jj's root for $ws is not $ws"
    wt_paths | grep -xF >/dev/null "$ws" || die "git lists no worktree at $ws"
    [ "$(git -C "$ws" rev-parse HEAD)" = "$base" ] || die "git HEAD in $ws is not main@origin"

    done=1
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
