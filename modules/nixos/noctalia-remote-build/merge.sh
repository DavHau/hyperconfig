# Seed the remote-build CustomButton into noctalia's settings.json.
#
# Append-only: if any CustomButton in the bar already runs
# remote-build-toggle (any section, any screen override), do nothing —
# the user may have moved or restyled it. Missing/corrupt settings.json
# starts from {}.
#
# Placement: immediately BEFORE the ControlCenter widget (the noctalia
# owl) when present, so the owl stays the rightmost icon; plain append
# otherwise.
set -euo pipefail

cfgDir="${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
target="$cfgDir/settings.json"
mkdir -p "$cfgDir"

widget='{
  "id": "CustomButton",
  "icon": "cloud-upload",
  "leftClickExec": "/run/current-system/sw/bin/remote-build-toggle toggle",
  "leftClickUpdateText": true,
  "textCommand": "/run/current-system/sw/bin/remote-build-toggle status",
  "textIntervalMs": 5000,
  "parseJson": true
}'

if ! existing="$(jq -e . "$target" 2>/dev/null)"; then
  existing='{}'
fi

tmp="$(mktemp "$cfgDir/.remote-build-merge.XXXXXX")"
printf '%s' "$existing" | jq --argjson w "$widget" '
  if ([.. | objects | select(.id? == "CustomButton")
         | .textCommand // "" | select(test("remote-build-toggle"))]
      | length) > 0
  then .
  else .bar.widgets.right = ((.bar.widgets.right // []) as $r
    | if any($r[]; .id? == "ControlCenter")
      then [$r[] | if .id? == "ControlCenter" then $w, . else . end]
      else $r + [$w]
      end)
  end
' > "$tmp"
mv "$tmp" "$target"
