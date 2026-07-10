# Seed the anthropic-usage noctalia plugin into ~/.config/noctalia.
#
# Runs as an extra noctalia-shell ExecStartPre AFTER the spaces bundle's
# noctalia-config-merge, so spaces' managed keys are already in place.
# Unlike that merge this one only APPENDS: the user's own widget layout
# and plugin states survive every restart.
#
# Requires on PATH: jq, coreutils. Requires in env:
#   ANTHROPIC_USAGE_PLUGIN_SRC  plugin source dir (manifest + QML)
set -euo pipefail

src="$ANTHROPIC_USAGE_PLUGIN_SRC"
cfgDir="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"

# jq FILTER FILE — rewrite FILE in place (missing/corrupt -> {}).
rewriteJson() {
  local filter="$1" target="$2" existing tmp
  mkdir -p "$(dirname "$target")"
  if ! existing="$(jq -e . "$target" 2>/dev/null)"; then
    existing='{}'
  fi
  tmp="$(mktemp "$(dirname "$target")/.anthropic-usage-merge.XXXXXX")"
  printf '%s' "$existing" | jq "$filter" > "$tmp"
  mv "$tmp" "$target"
}

# Materialise the plugin: per-file symlinks under a REAL plugins/<id>/
# dir. The spaces stale-plugin purge sweeps top-level symlinks in
# plugins/, and noctalia writes its own settings.json into the dir at
# runtime — per-file links keep manifest/QML tracking the store while
# leaving both alone.
dst="$cfgDir/plugins/anthropic-usage"
mkdir -p "$dst"
for f in "$src"/*; do
  ln -sfn "$f" "$dst/$(basename "$f")"
done

# Enable the plugin; every other state survives.
rewriteJson '.states."anthropic-usage".enabled = true' "$cfgDir/plugins.json"

# Append the bar widget to the right section if it is not there yet.
# Append, not pin: the rest of the user's right-side layout is theirs.
rewriteJson '
  .bar.widgets.right = (
    (.bar.widgets.right // [])
    | if any(.[]; .id == "plugin:anthropic-usage")
      then .
      else . + [{"id": "plugin:anthropic-usage"}]
      end
  )' "$cfgDir/settings.json"
