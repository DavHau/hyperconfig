--!nonstrict
-- Generic status/toggle bar button.
--
-- Every `interval_ms` the widget runs `status_command` (through /bin/sh) and
-- expects one JSON object on stdout:
--   { "icon": "<tabler glyph>", "iconColor": "<palette role>", "tooltip": "...", "text": "..." }
-- All fields are optional. `iconColor` is a palette role ("primary", "on_surface",
-- the v4 spellings "mPrimary"/"onSurface" are accepted too) or a #hex color; absent,
-- "none" or unknown resets the glyph to the widget's default color.
-- A failed command or non-JSON output keeps the last state.
-- Left click runs `toggle_command`, then polls the status right away.

local statusCommand: string = noctalia.getConfig("status_command") or ""
local toggleCommand: string = noctalia.getConfig("toggle_command") or ""
local intervalMs: number = noctalia.getConfig("interval_ms") or 5000
local initialGlyph: string = noctalia.getConfig("glyph") or "circle"

local ROLES = {
  primary = true,
  on_primary = true,
  secondary = true,
  on_secondary = true,
  tertiary = true,
  on_tertiary = true,
  error = true,
  on_error = true,
  surface = true,
  on_surface = true,
  surface_variant = true,
  on_surface_variant = true,
  outline = true,
  shadow = true,
  hover = true,
  on_hover = true,
}

-- Palette role or #hex for a status `iconColor`; nil means "widget default".
local function colorFor(value: any): string?
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if string.match(value, "^#%x+$") then
    local n = #value - 1
    if n == 3 or n == 4 or n == 6 or n == 8 then
      return value
    end
    return nil
  end
  -- v4 names: "mPrimary" / "onSurface" / "primary" -> snake_case v5 roles.
  local role = string.gsub(value, "^m(%u)", "%1")
  role = string.lower((string.gsub(role, "(%l)(%u)", "%1_%2")))
  if ROLES[role] then
    return role
  end
  return nil
end

local shown = {
  glyph = initialGlyph,
  color = nil :: string?,
  tooltip = "",
  text = "",
}

local function render()
  barWidget.setGlyph(shown.glyph)
  -- "on_surface" in the default mode keeps the widget's configured icon color.
  barWidget.setGlyphColor(shown.color or "on_surface")
  barWidget.setText(shown.text)
  if shown.tooltip ~= "" then
    barWidget.setTooltip(shown.tooltip)
  else
    barWidget.clearTooltip()
  end
end

local function apply(stdout: string)
  local line = noctalia.string.trim(stdout)
  -- Only the first line is the status; ignore anything a tool printed after it.
  local first = string.match(line, "^[^\n]*") or ""
  local ok, data = pcall(noctalia.json.decode, first)
  if not ok or type(data) ~= "table" then
    return
  end
  if type(data.icon) == "string" and data.icon ~= "" then
    shown.glyph = data.icon
  end
  shown.color = colorFor(data.iconColor)
  shown.tooltip = if type(data.tooltip) == "string" then data.tooltip else ""
  shown.text = if type(data.text) == "string" then data.text else ""
  render()
end

-- Each poll gets a sequence number; only the newest poll's answer is applied,
-- so a poll started before a toggle cannot overwrite the post-toggle state.
local latestPoll = 0
local inFlight = false

local function poll()
  if statusCommand == "" then
    return
  end
  latestPoll += 1
  local seq = latestPoll
  inFlight = true
  local started = noctalia.runAsync(statusCommand, function(result)
    if seq ~= latestPoll then
      return
    end
    inFlight = false
    if result.exitCode == 0 and not result.timedOut then
      apply(result.stdout or "")
    end
  end)
  if not started then
    inFlight = false
  end
end

function update()
  if not inFlight then
    poll()
  end
end

function onClick()
  if toggleCommand == "" then
    poll()
    return
  end
  local started = noctalia.runAsync(toggleCommand, function(_result)
    poll()
  end)
  if not started then
    poll()
  end
end

noctalia.setUpdateInterval(intervalMs)
render()
poll()
