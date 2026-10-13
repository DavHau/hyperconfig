#!/usr/bin/env bash
# One-shot move of the agents' state to the layout services.hermes-native
# expects: /var/lib/hermes-microvm/<u>/state-vault/state -> /var/lib/hermes/<u>/state.
# Not part of the NixOS config. Run on the agent host as root BEFORE switching
# to the config that expects the new path; the new units would otherwise
# start on an empty state dir.
#
#   migrate-state.sh [--dry-run] [<agent>...]
#
# Without agent names it migrates every agent of som. Per agent it stops the
# agent's units, moves the state dir (a rename: same filesystem; owner and
# modes stay), deletes the python venv (absolute paths inside; the venv unit
# rebuilds it after the switch), deletes the retired SimpleX state, rewrites
# the old absolute path in the agent's own config files, and removes what the
# old layout left behind. Idempotent: an agent whose state already sits at
# the new path is skipped.
set -eu

dry=0
if [ "${1:-}" = "--dry-run" ]; then
  dry=1
  shift
fi
if [ $# -gt 0 ]; then
  agents="$*"
else
  agents="adam chris dave-hermes domi egg j momentum pinpox rti stefan willi"
fi

old_root=/var/lib/hermes-microvm
new_root=/var/lib/hermes

run() {
  echo "+ $*"
  if [ "$dry" = 0 ]; then "$@"; fi
}

[ "$(id -u)" = 0 ] || {
  echo "migrate-state: run as root" >&2
  exit 1
}

run install -d -m 0755 -o root -g root "$new_root"

for u in $agents; do
  old="$old_root/$u/state-vault/state"
  new="$new_root/$u/state"
  echo "== $u"
  id "$u" >/dev/null

  if [ ! -d "$old" ]; then
    if [ -d "$new" ]; then
      echo "already at $new, skipping"
      continue
    fi
    echo "migrate-state: neither $old nor $new exists" >&2
    exit 1
  fi
  if [ -e "$new" ]; then
    # An empty dir is what tmpfiles creates if the new config ran first.
    if [ -d "$new" ] && [ -z "$(ls -A "$new")" ]; then
      run rmdir "$new"
    else
      echo "migrate-state: both $old and $new exist; merge by hand" >&2
      exit 1
    fi
  fi

  # Every unit of the old layout that opens the state dir, and the
  # retired SimpleX forward.
  for unit in \
    "hermes-agent-$u.service" \
    "hermes-dashboard-$u.service" \
    "hermes-python-venv-$u.service" \
    "hermes-simplex-address-$u.service" \
    "hermes-simplex-$u.service" \
    "hermes-simplex-fwd-$u.socket"; do
    if systemctl is-active --quiet "$unit"; then
      run systemctl stop "$unit"
    fi
  done
  if [ "$dry" = 0 ]; then
    for unit in "hermes-agent-$u.service" "hermes-dashboard-$u.service" "hermes-simplex-$u.service"; do
      if systemctl is-active --quiet "$unit"; then
        echo "migrate-state: $unit is still active" >&2
        exit 1
      fi
    done
  fi
  # Interactive sessions (ssh `hermes`, hermes-desktop's `hermes serve`)
  # may still hold the state open; they are the owner's, so only warn.
  if pgrep -u "$u" -f "$old" >/dev/null 2>&1; then
    echo "warning: processes of $u still reference $old:" >&2
    pgrep -a -u "$u" -f "$old" >&2 || true
  fi

  run install -d -m 0711 -o root -g root "$new_root/$u"
  run mv "$old" "$new"
  run chown "$u:users" "$new"
  run chmod 0700 "$new"
  run rm -rf "$new/.venv" "$new/simplex"
  run rm -f "/home/$u/hermes/simplex-address.txt"

  # The agent's own config that names its state by absolute path. Logs,
  # sessions and databases keep the old path as history. Run as the owner,
  # so the rewritten files keep their owner.
  dir="$new"
  [ "$dry" = 1 ] && dir="$old"
  for f in \
    "$dir/.hermes/config.yaml" \
    "$dir/.hermes/.env" \
    "$dir/.hermes/SOUL.md" \
    "$dir/.hermes/cron/jobs.json" \
    "$dir"/.hermes/memories/*; do
    [ -f "$f" ] || continue
    if grep -qF "$old" "$f"; then
      run runuser -u "$u" -- sed -i "s|$old|$new|g" "${f/#$dir/$new}"
    fi
  done

  # What the old layout left beside the state dir.
  run rm -f "$old_root/$u/desktop-token"
  if [ "$dry" = 0 ]; then
    rmdir "$old_root/$u/state-vault"
    rmdir "$old_root/$u" 2>/dev/null || echo "left in $old_root/$u: $(ls -A "$old_root/$u" | tr '\n' ' ')"
  fi
done

# The SearXNG secret moves to /var/lib/hermes-searxng; a fresh key only
# logs out web-UI sessions.
run rm -rf /var/lib/spaces-searxng
