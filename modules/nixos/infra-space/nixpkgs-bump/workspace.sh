# nixpkgs-bump-workspace: creates and removes an unattended job's jj
# workspace, so the run never parses jj's output to decide whether it has
# one. Used by the security jobs (../security-jobs.nix builds it under
# their own name and prefix); the nightly bump no longer uses it (it
# starts fresh each night, ../nixpkgs-bump/SKILL.md), the defaults below
# keep its old names for ./workspace-test.nix.
#
#   nixpkgs-bump-workspace create [NAME]
#   nixpkgs-bump-workspace alive NAME
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
# create: fetch, then the earlier nights first. Any hyperconfig-nixpkgs-
# bump-* beside the repository (a directory, a jj workspace, a git
# worktree) or in @logDir@ (.old-rev, .searxng-*) is an earlier run's:
# - still running: exit 1, nothing touched (two runs must not overlap);
#   if listing them fails, exit 1 too. Running means its liveness stamp
#   @logDir@/NAME.alive (written by create, refreshed by `alive NAME` at
#   each step of the run and by nixpkgs-bump-nix while a command runs in
#   the workspace) is younger than @aliveMinutes@ minutes, or a file in
#   it changed in the last @liveMinutes@ minutes, or a process has its
#   cwd in it (see is_live). The stamp is the run's own word: hermes runs
#   each terminal call in a fresh shell, and a quiet hour of polling a
#   build looks like nothing else;
# - not this helper's to judge (foreign content, a .jj or .git that is
#   not jj's own, see remove): left alone (`SKIP:` and `LEFT:` lines),
#   and the run goes on beside it;
# - otherwise taken over: its unpushed work (snapshotted first) is kept
#   as the local bookmark nixpkgs-bump-archive/<its name> (never pushed),
#   then it is removed like `remove` does (`TAKEOVER:` line). A leftover
#   never stops a run.
# Archive bookmarks older than @archiveDays@ days (their commit's committer
# date) are deleted first (local bookmarks only, never pushed).
# Then `mkdir` (no -p) and the workspace. The mkdir is a lock only
# against a parallel run with the same NAME (with the default, one
# started on the same UTC date); a run with another name is kept out by
# the liveness check alone. Then the carry: the newest archived
# leftover's non-empty commits not in main@origin are duplicated, in
# order, on top of main@origin, without their flake.lock changes (the
# run moves the lock itself; a commit left empty by that is dropped). If
# one conflicts, none is carried: the run starts fresh, the archive
# stays (`CARRIED:` or `FRESH:` line). Its stdout is exactly the
# workspace's path; everything else is on stderr. Exit 0 only once the
# facts hold: jj lists the workspace, its @ is an empty change on top of
# main@origin or of the carried commits (which descend from main@origin,
# conflict-free), the tree is checked out, and git lists the worktree.
# Any failure after the mkdir removes what this call created (no bump
# work of its own yet; carried commits are copies of the archive) and
# exits 1, so one odd night cannot block the next ones.
#
# Why `add` from the new destination and then `jj new` there: `workspace
# add` run in the repository snapshots and updates its own working copy
# (stray files there would be committed), and current jj refuses add with
# --ignore-working-copy. The empty destination has nothing to snapshot.
# `jj new main@origin` checks the tree out; the facts above decide.
#
# alive NAME touches @logDir@/NAME.alive (NAME's directory must exist):
# the run's liveness stamp, see create.
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
# (jj also drops its git worktree), removes DIR, @logDir@/NAME.old-rev and
# NAME.searxng-* (./searxng.sh's pick, diff and its parts, review and
# canary files), NAME.alive,
# prunes git's worktree entries, and exits 0 only if none of them is left
# (a failing listing counts as left).

repo=@repo@
logDir=@logDir@
prefix=@prefix@

say() { echo "@name@: $*" >&2; }
die() {
  say "FAIL: $*"
  exit 1
}
usage() {
  echo "usage: @name@ create [NAME] | alive NAME | remove NAME" >&2
  exit 2
}

cmd=${1:-}
[ $# -ge 1 ] && shift

# Every path here is absolute; the caller's cwd may be unreadable to us
# (`runuser -u infra` from /root): find fails when it cannot return to
# its starting directory, which would read as a failed listing.
cd /
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
  [ -e "$logDir/$name.alive" ] && echo "$logDir/$name.alive"
  for f in "$logDir/$name".searxng-{pick,diff,review,canary} "$logDir/$name".searxng-diff.part-*; do
    [ -e "$f" ] && echo "$f"
  done
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
# $1's, by path, and all of its work is in main@origin. With $2 (a
# takeover's archive bookmark), unpushed work does not refuse: it is kept
# as bookmark $2 first.
check_remove() {
  local name=$1 ws=$parent/$1 archive=${2:-} list paths byname bypath admin unpushed e
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
  [ -z "$unpushed" ] && return 0
  [ -n "$archive" ] ||
    die "$name has work not in main@origin, touching nothing: $(echo "$unpushed" | paste -sd ' ' -)"
  jjr bookmark set --allow-backwards "$archive" -r "\"$name\"@" >&2 ||
    die "cannot keep $name's work as bookmark $archive, touching nothing"
  [ "$(jjr log --no-graph -r "bookmarks(exact:\"$archive\")" -T commit_id)" = \
    "$(jjr log --no-graph -r "\"$name\"@" -T commit_id)" ] ||
    die "bookmark $archive is not at $name@, touching nothing"
  say "TAKEOVER: $name's unpushed work ($(echo "$unpushed" | paste -sd ' ' -)) archived as $archive"
}

remove() {
  local name=$1 ws=$parent/$1 archive=${2:-}
  check_remove "$name" "$archive"
  if ws_list | grep -xF >/dev/null -- "\"$name\" \"$ws\""; then
    jjr workspace forget "$name" >&2 || say "jj workspace forget $name failed"
  fi
  if wt_paths | grep -xF >/dev/null -- "$ws"; then
    git -C "$repo" worktree remove --force "$ws" >&2 || true
  fi
  rm -rf -- "${parent:?}/$name"
  rm -f -- "$logDir/$name.old-rev" "$logDir/$name.alive" "$logDir/$name".searxng-{pick,diff,review,canary} "$logDir/$name".searxng-diff.part-*
  git -C "$repo" worktree prune >&2 || say "git worktree prune failed"
  local left
  left=$(leftovers "$name")
  [ -z "$left" ] || die "left behind: $(echo "$left" | paste -sd ';' -)"
}

# Every earlier night's bump name, one per line, sorted (the default
# names sort by date): directories and symlinks beside the repository,
# jj workspaces, git worktrees and git's worktree entries, and the
# .old-rev / .alive / .searxng-* files in @logDir@. Exit 1 if a listing fails.
earlier_names() {
  local dirs names paths admin files
  dirs=$(find "$parent" -mindepth 1 -maxdepth 1 -name "$prefix*" -printf '%f\n') || return 1
  names=$(ws_names) || return 1
  paths=$(wt_paths) || return 1
  admin=
  if [ -d "$repo/.git/worktrees" ]; then
    admin=$(find "$repo/.git/worktrees" -mindepth 1 -maxdepth 1 -name "$prefix*" -printf '%f\n') || return 1
  fi
  files=
  if [ -d "$logDir" ]; then
    files=$(find "$logDir" -mindepth 1 -maxdepth 1 \( -name "$prefix*.old-rev" -o -name "$prefix*.alive" -o -name "$prefix*.searxng-*" \) -printf '%f\n' |
      sed -e 's/\.old-rev$//' -e 's/\.alive$//' -e 's/\.searxng-.*$//') || return 1
  fi
  {
    echo "$dirs"
    filter -E -- "^$prefix" <<<"$names"
    filter -F -- "$parent/$prefix" <<<"$paths" | sed 's|.*/||'
    echo "$admin"
    echo "$files"
  } | sed '/^$/d' | sort -u
}

# Exit 0 (with the reason on stdout) if bump workspace $1 is in use: its
# liveness stamp @logDir@/$1.alive is younger than @aliveMinutes@ minutes
# (the run says it is alive), a file there changed in the last @liveMinutes@ minutes (the agent
# editing, a build writing result-*), or a process has its cwd there and
# something changed within @staleMinutes@ minutes (a long build). Otherwise the
# run is taken for dead: the timer is 24 h apart, the unit's limit 16 h.
is_live() {
  local ws=$parent/$1 p cwd hit stamp=$logDir/$1.alive
  if [ -f "$stamp" ] && [ ! -L "$stamp" ] &&
    [ -n "$(find "$stamp" -mmin -@aliveMinutes@ -print 2>/dev/null)" ]; then
    echo "its liveness stamp $stamp is younger than @aliveMinutes@ minutes"
    return 0
  fi
  [ -d "$ws" ] && [ ! -L "$ws" ] || return 1
  hit=$(find "$ws" -xdev -mmin -@liveMinutes@ -print -quit 2>/dev/null)
  if [ -n "$hit" ]; then
    echo "$hit changed in the last @liveMinutes@ minutes"
    return 0
  fi
  # A process working in it (a build's client, the agent's shell) counts
  # while the directory changed within @staleMinutes@ minutes: a shell left behind
  # by a run that died does not hold the bump off forever.
  [ -n "$(find "$ws" -xdev -mmin -@staleMinutes@ -print -quit 2>/dev/null)" ] || return 1
  for p in /proc/[0-9]*; do
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    case "$cwd" in
      "$ws" | "$ws"/*)
        echo "process ${p#/proc/} works in it"
        return 0
        ;;
    esac
  done
  return 1
}

# Takes over an earlier night's leftovers $1: its unpushed work kept as
# bookmark nixpkgs-bump-archive/$1 (`TAKEOVER: ... archived as <bookmark>`
# when there was some), then removed as by `remove`. Exit 1 (nothing
# touched but the bookmark) when remove would refuse for another reason.
takeover() {
  local name=$1
  check_name "$name"
  remove "$name" "nixpkgs-bump-archive/$name"
  say "TAKEOVER: removed the earlier night's $name"
}

# The carry: the archived night's commits (non-empty, not in
# main@origin), duplicated in order between main@origin and the new
# workspace's @, without their flake.lock changes; commits that end up
# empty are dropped. Exit 1 (the new workspace back at a fresh @ on
# main@origin) if one conflicts.
carry() {
  local archive=$1 ws=$2 base=$3 c revs n
  revs="(::bookmarks(exact:\"$archive\") ~ ::main@origin) ~ empty()"
  n=$(jj -R "$ws" log --no-graph -r "$revs" -T '"x\n"' | grep -c x) || true
  [ "$n" -gt 0 ] || return 0
  jj -R "$ws" duplicate "$revs" -B @ >&2 || return 1
  for c in $(jj -R "$ws" log --no-graph --reversed -r 'main@origin..@-' -T 'change_id ++ "\n"'); do
    jj -R "$ws" restore -c "$c" 'root-file:"flake.lock"' >&2 || return 1
  done
  if [ -n "$(jj -R "$ws" log --no-graph -r '(main@origin..@-) & empty()' -T change_id)" ]; then
    jj -R "$ws" abandon '(main@origin..@-) & empty()' >&2 || return 1
  fi
  [ -z "$(jj -R "$ws" log --no-graph -r '(main@origin..@) & conflicts()' -T change_id)" ] || return 1
  [ "$(jj -R "$ws" log --no-graph -r @ -T 'if(empty, "empty")')" = empty ] || return 1
  [ -n "$(jj -R "$ws" log --no-graph -r "$base & ::@" -T commit_id)" ] || return 1
}

case "$cmd" in
  create)
    [ $# -le 1 ] || usage
    name=${1:-$prefix$(date -u +%F)}
    check_name "$name"
    ws=$parent/$name
    # stdout is the path alone: everything else to stderr
    exec 3>&1 1>&2

    jjr git fetch >&2 || die "jj git fetch failed"

    # The earlier nights: every bump name in any form; a listing that
    # fails is a refusal.
    earlier=$(earlier_names) || die "listing the earlier bump workspaces failed, touching nothing"
    IFS=$'\n'
    # A live one stops this run before anything is touched.
    for n in $earlier; do
      if why=$(is_live "$n"); then
        die "bump workspace $n is in use ($why): an earlier run is still going, touching nothing"
      fi
    done
    # Old archives go (local bookmarks only; never pushed).
    while IFS=$'\t' read -r b t; do
      [ -n "$b" ] && [ -n "$t" ] || continue
      if [ "$t" -lt "$(($(date +%s) - @archiveDays@ * 86400))" ]; then
        jjr bookmark delete "exact:\"$b\"" >&2 && say "PRUNED: archive $b (older than @archiveDays@ days)"
      fi
    done < <(jjr bookmark list "glob:nixpkgs-bump-archive/*" \
      -T 'if(!remote && normal_target, name ++ "\t" ++ normal_target.committer().timestamp().format("%s") ++ "\n")')
    archive=
    for n in $earlier; do
      if out=$(takeover "$n" 2>&1); then
        echo "$out"
        b=$(sed -n 's/^@name@: TAKEOVER: .* archived as \([^ ]*\)$/\1/p' <<<"$out")
        # names sort by date: the last one archived is the newest night's
        [ -z "$b" ] || archive=$b
      else
        echo "$out"
        say "SKIP: $n is not this helper's to take over; the run goes on beside it"
        while IFS= read -r l; do [ -z "$l" ] || say "LEFT: $l"; done < <(leftovers "$n")
      fi
    done
    unset IFS

    mkdir -- "$ws" || die "mkdir $ws failed: another run got there first, touching nothing"
    { mkdir -p -- "$logDir" && touch -- "$logDir/$name.alive"; } || die "cannot write the liveness stamp $logDir/$name.alive"

    # From here on the workspace is this call's: on any failure remove it.
    done=0
    on_exit() {
      if [ "$done" != 1 ]; then
        say "removing the workspace this call created: $ws"
        # carried commits are copies of the archive (which keeps them)
        jj -R "$ws" abandon 'main@origin..@' >/dev/null 2>&1 || true
        (remove "$name") || say "cleanup incomplete; the next run takes it over"
      fi
      rm -rf -- "$jjHome"
    }

    base=$(jjr log --no-graph -r main@origin -T commit_id) || die "no main@origin"
    # Run from the new, empty destination: current jj refuses `workspace
    # add --ignore-working-copy`, while a repository working directory can
    # snapshot stray files from the main checkout.
    (cd "$ws" && jj --config 'snapshot.auto-track="none()"' -R "$repo" \
      workspace add --colocate -r main@origin "$ws") >&2 || die "jj workspace add $name failed"
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

    # Carry the newest earlier night's work forward, or start fresh.
    if [ -n "$archive" ]; then
      if carry "$archive" "$ws" "$base"; then
        say "CARRIED: $(jj -R "$ws" log --no-graph -r 'main@origin..@-' -T 'change_id.short(8) ++ " " ++ description.first_line() ++ "; "') from $archive (flake.lock changes dropped: move the lock again)"
      else
        say "FRESH: $archive does not apply to main@origin ($base): starting fresh; it stays as that bookmark"
        # drop what the carry made (copies; @ comes back empty on main@origin)
        jj -R "$ws" abandon 'main@origin..@' >&2 || die "cannot drop the carry in $ws"
        [ "$(jj -R "$ws" log --no-graph -r '@-' -T commit_id)" = "$base" ] ||
          die "@- in $ws is not main@origin after dropping the carry"
      fi
      [ -z "$(jj -R "$ws" log --no-graph -r '(main@origin..@) & conflicts()' -T change_id)" ] ||
        die "conflicted commits in $ws"
      [ "$(jj -R "$ws" log --no-graph -r @ -T 'if(empty, "empty")')" = empty ] ||
        die "@ in $ws is not empty"
      [ -f "$ws/flake.nix" ] && [ -f "$ws/flake.lock" ] || die "no tree checked out in $ws"
    fi

    done=1
    say "ok: $name: @ empty on $(jj -R "$ws" log --no-graph -r '@-' -T 'commit_id') (main@origin $base)"
    echo "$ws" >&3
    ;;
  alive)
    [ $# = 1 ] || usage
    check_name "$1"
    [ -d "$parent/$1" ] && [ ! -L "$parent/$1" ] || die "no bump workspace $parent/$1"
    [ ! -L "$logDir/$1.alive" ] || die "$logDir/$1.alive is a symlink"
    touch -- "$logDir/$1.alive"
    ;;
  remove)
    [ $# = 1 ] || usage
    check_name "$1"
    remove "$1"
    say "ok: removed $1"
    ;;
  *) usage ;;
esac
