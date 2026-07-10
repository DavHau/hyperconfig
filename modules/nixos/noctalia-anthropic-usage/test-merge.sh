#!/usr/bin/env bash
# Behavior tests for the anthropic-usage noctalia config merge
# (merge.sh, the extra ExecStartPre that runs AFTER the spaces bundle's
# own noctalia-config-merge).
#
# Contract:
#   1. materialises the plugin as per-file symlinks under a REAL
#      plugins/anthropic-usage/ dir (spaces' stale-plugin purge sweeps
#      top-level symlinks in plugins/; a real dir survives, and noctalia
#      can write its own settings.json next to the links);
#   2. enables the plugin in plugins.json without touching other states;
#   3. appends plugin:anthropic-usage to bar.widgets.right — APPEND, not
#      pin: the user's own right-side widget choices survive;
#   4. is idempotent: a second run (every bar restart) adds nothing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
MERGE="${MERGE:-$here/merge.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

export HOME
HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
cfg="$HOME/.config/noctalia"
mkdir -p "$cfg"

export ANTHROPIC_USAGE_PLUGIN_SRC="$here/plugin"

# State the spaces merge leaves behind: pinned center, user-chosen right,
# one marketplace plugin already enabled.
cat > "$cfg/settings.json" <<'EOF'
{ "bar": { "position": "top",
           "widgets": { "center": [ {"id":"Workspace"}, {"id":"plugin:spaces-sessions"} ],
                        "right":  [ {"id":"Tray"}, {"id":"Clock"} ] } },
  "general": { "avatar": "x" } }
EOF
cat > "$cfg/plugins.json" <<'EOF'
{ "states": { "spaces-sessions": { "enabled": true } } }
EOF

bash "$MERGE"

# --- 1: plugin materialised as per-file symlinks in a real dir -----------
[ -d "$cfg/plugins/anthropic-usage" ] || fail "plugins/anthropic-usage is not a directory"
[ ! -L "$cfg/plugins/anthropic-usage" ] || fail "plugins/anthropic-usage must be a real dir, not a symlink"
for f in manifest.json Main.qml BarWidget.qml; do
  [ -L "$cfg/plugins/anthropic-usage/$f" ] || fail "$f not symlinked into the plugin dir"
done
ok "plugin materialised as per-file symlinks"

# --- 2: enabled in plugins.json, other states untouched -------------------
jq -e '.states."anthropic-usage".enabled == true' "$cfg/plugins.json" >/dev/null \
  || fail "plugin not enabled in plugins.json"
jq -e '.states."spaces-sessions".enabled == true' "$cfg/plugins.json" >/dev/null \
  || fail "existing plugin state clobbered"
ok "plugins.json enabled without clobbering"

# --- 3: widget appended to bar.widgets.right, user widgets survive --------
jq -e '.bar.widgets.right == [{"id":"Tray"},{"id":"Clock"},{"id":"plugin:anthropic-usage"}]' \
  "$cfg/settings.json" >/dev/null || fail "widget not appended to right: $(jq -c .bar.widgets.right "$cfg/settings.json")"
jq -e '.bar.widgets.center == [{"id":"Workspace"},{"id":"plugin:spaces-sessions"}]' \
  "$cfg/settings.json" >/dev/null || fail "center list was touched"
jq -e '.general.avatar == "x"' "$cfg/settings.json" >/dev/null || fail "unrelated settings lost"
ok "widget appended to right, everything else untouched"

# --- 4: idempotent ---------------------------------------------------------
bash "$MERGE"
count=$(jq '[.bar.widgets.right[] | select(.id == "plugin:anthropic-usage")] | length' "$cfg/settings.json")
[ "$count" = "1" ] || fail "second run duplicated the widget ($count entries)"
ok "second run is a no-op"

# --- 5: fresh host — no settings.json/plugins.json yet ---------------------
rm -rf "$cfg"
mkdir -p "$cfg"
bash "$MERGE"
jq -e '.bar.widgets.right == [{"id":"plugin:anthropic-usage"}]' "$cfg/settings.json" >/dev/null \
  || fail "fresh host: widget not seeded"
jq -e '.states."anthropic-usage".enabled == true' "$cfg/plugins.json" >/dev/null \
  || fail "fresh host: plugin not enabled"
ok "fresh host seeds both files"

echo "PASS: merge script behavior tests"
