# Delete cargo build dirs (see ../rust-build-cache.nix) that are dead:
#  - their workspace is gone (build dirs are keyed by workspace path:
#    <root><workspace-root>), e.g. a finished omp task worktree, or
#  - no file in them changed for CARGO_BUILD_GC_DAYS days.
# Covers the host cache and every sbox project's persisted copy of it.
#
# Inside sbox a workspace may exist only in a session: omp worktrees live
# in the session's scratch tree (../sbox-omp-worktrees.nix), scratch
# projects in its $HOME or /tmp. Such a workspace counts only while its
# session is live; a dead session's build dirs are garbage even if its
# worktree is still kept for --resume.
days="${CARGO_BUILD_GC_DAYS:-14}"
sbox_state="${XDG_STATE_HOME:-$HOME/.local/state}/sbox"
sbox_scratch="${XDG_DATA_HOME:-$HOME/.local/share}/sbox/scratch"

# Build dir roots below $1: directories holding cargo's .rustc_info.json.
build_dirs() {
  find "$1" -mindepth 1 -type d \( -exec test -e '{}/.rustc_info.json' \; -prune -print0 \)
}

# $1 = workspace path inside the sandbox, $2 = project path (state key).
in_live_session() {
  local sessions="$sbox_state/projects$2/sessions" s
  [ -d "$sessions" ] || return 1
  for s in "$sessions"/*/; do
    s="${s%/}"
    [ -e "$s/.lock" ] || continue
    flock -n "$s/.lock" true && continue # lock free: session is dead
    if [ -d "$s$1" ] || [ -d "$sbox_scratch${s#"$sbox_state"}$1" ]; then
      return 0
    fi
  done
  return 1
}

# $1 = build dir root, $2 = project path for sbox roots (empty for host).
gc_root() {
  local root="$1" project="$2" dir ws parent
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' dir; do
    ws="${dir#"$root"}"
    if [ -d "$ws" ] || { [ -n "$project" ] && in_live_session "$ws" "$project"; }; then
      # Any file touched within the window (e.g. a running build) keeps it.
      [ -n "$(find "$dir" -newermt "-${days} days" -print -quit)" ] && continue
    fi
    echo "removing $dir"
    rm -rf --one-file-system "$dir"
    # Drop the mirrored path components the removal left empty.
    parent="${dir%/*}"
    while [ "$parent" != "$root" ] && rmdir "$parent" 2>/dev/null; do
      parent="${parent%/*}"
    done
  done < <(build_dirs "$root")
}

gc_root "$HOME/.cache/cargo-build" ""

if [ -d "$sbox_state/projects" ]; then
  # Session trees and persist dirs are large: prune at both, then look only
  # at each project's persisted build dir.
  while IFS= read -r -d '' persist; do
    project="${persist#"$sbox_state/projects"}"
    project="${project%/persist}"
    gc_root "$persist$HOME/.cargo/build-dir" "$project"
  done < <(find "$sbox_state/projects" -type d \( -name sessions -o -name persist \) -prune -name persist -print0)
fi
