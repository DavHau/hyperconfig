--!nonstrict
-- Anthropic Weekly Usage - bar widget.
--
-- Reads the state file the anthropic-usage-poll user timer publishes
-- ($XDG_STATE_HOME/anthropic-usage.json, default ~/.local/state/...):
--   { version: 3, updatedAt,
--     accounts: [ { email, weekly, weeklyResetsAt, fable, fableResetsAt, fetchedAt, stale } ] }
--   weekly / fable in 0..100 or null; *ResetsAt epoch ms or null;
--   fetchedAt epoch ms of the last successful fetch or null.
--
-- One thin gauge per account, stacked across the bar. Each gauge overlays two
-- fills on one track: weekly all-model usage (primary) and weekly Fable usage
-- (tertiary). The wider fill sits underneath so both stay visible. A fill at
-- >= 80% turns error; stale data (failed fetch) dims both. Hidden while there
-- are no accounts. The tooltip lists each account's percentages, reset times
-- and, for stale accounts, when it was last fetched.

-- Gauge geometry in logical px (the host scales by the widget scale). Sized
-- for the default bar (thickness 34, capsule 0.76): the stack of gauges stays
-- within CROSS_BUDGET across the bar.
local GAUGE_LENGTH = 42
local MAX_THICKNESS = 6
local MIN_THICKNESS = 3
local GAP = 3
local CROSS_BUDGET = 20

local WARN_PERCENT = 80
local STALE_ALPHA = 0.4
local CHECK_INTERVAL_MS = 5000
local TIME_FORMAT = "{:%a %H:%M}"

local stateHome = noctalia.getenv("XDG_STATE_HOME")
local statePath = if stateHome ~= nil and stateHome ~= ""
  then stateHome .. "/anthropic-usage.json"
  else "~/.local/state/anthropic-usage.json"

local accounts = {}
local lastStamp: string? = nil

local function pct(p: any): string
  if type(p) ~= "number" then
    return "?"
  end
  return string.format("%d%%", math.floor(p + 0.5))
end

local function usageText(p: any, resetsAt: any): string
  if type(p) ~= "number" then
    return "?"
  end
  if type(resetsAt) ~= "number" then
    return pct(p)
  end
  return pct(p) .. ", resets " .. noctalia.formatTime(TIME_FORMAT, resetsAt // 1000)
end

local function fraction(p: any): number
  if type(p) ~= "number" then
    return 0
  end
  return math.clamp(p / 100, 0, 1)
end

local function fillColor(p: any, base: string, stale: boolean): string
  local role = if type(p) == "number" and p >= WARN_PERCENT then "error" else base
  if stale then
    return role .. "/" .. tostring(STALE_ALPHA)
  end
  return role
end

-- Sized for noctalia's tooltip table (280 px across key + value): keys are
-- the email's local part, values stay within ~21 monospace characters.
local function tooltipRows()
  local rows = {}
  for _, a in ipairs(accounts) do
    local status = ""
    if a.stale then
      status = if type(a.fetchedAt) == "number"
        then "stale since " .. noctalia.formatTime(TIME_FORMAT, a.fetchedAt // 1000)
        else "stale"
    end
    local name = string.match(tostring(a.email or "?"), "^([^@]*)") or "?"
    table.insert(rows, { key = name, value = status })
    table.insert(rows, { key = "  Weekly", value = usageText(a.weekly, a.weeklyResetsAt) })
    -- JSON null: the gateway has seen no Fable quota for this account.
    if type(a.fable) == "number" then
      table.insert(rows, { key = "  Fable", value = usageText(a.fable, a.fableResetsAt) })
    end
  end
  return rows
end

-- One gauge: track, wider fill on it, narrower fill inside the wider one.
-- Fills grow from the start of the track (left on a horizontal bar, bottom on
-- a vertical one).
local function gauge(a, index: number, thickness: number, vertical: boolean)
  local stale = a.stale == true
  local weekly = fraction(a.weekly)
  local fable = fraction(a.fable)
  local weeklyColor = fillColor(a.weekly, "primary", stale)
  local fableColor = fillColor(a.fable, "tertiary", stale)

  local wide, wideColor, narrow, narrowColor
  if weekly > fable then
    wide, wideColor, narrow, narrowColor = weekly, weeklyColor, fable, fableColor
  else
    wide, wideColor, narrow, narrowColor = fable, fableColor, weekly, weeklyColor
  end
  local wideLen = math.max(1, math.floor(wide * GAUGE_LENGTH + 0.5))
  local narrowLen = math.floor(narrow * GAUGE_LENGTH + 0.5)
  local radius = thickness / 2

  local container = if vertical then ui.column else ui.row
  local justify = if vertical then "end" else "start"
  local function size(len: number)
    if vertical then
      return thickness, len
    end
    return len, thickness
  end

  local trackW, trackH = size(GAUGE_LENGTH)
  local wideW, wideH = size(wideLen)
  local narrowW, narrowH = size(math.max(1, narrowLen))

  return container({
    key = "gauge-" .. tostring(index),
    width = trackW,
    height = trackH,
    radius = radius,
    fill = "surface_variant",
    justify = justify,
  }, {
    container({
      key = "wide",
      width = wideW,
      height = wideH,
      radius = radius,
      fill = wideColor,
      justify = justify,
      visible = wide > 0,
    }, {
      ui.box({
        key = "narrow",
        width = narrowW,
        height = narrowH,
        radius = radius,
        fill = narrowColor,
        visible = narrowLen > 0,
      }),
    }),
  })
end

local function render()
  local count = #accounts
  if count == 0 then
    barWidget.clearTooltip()
    barWidget.setVisible(false)
    return
  end

  local thickness = math.floor((CROSS_BUDGET - GAP * (count - 1)) / count)
  thickness = math.clamp(thickness, MIN_THICKNESS, MAX_THICKNESS)

  local vertical = barWidget.isVertical()
  local gauges = {}
  for i, a in ipairs(accounts) do
    table.insert(gauges, gauge(a, i, thickness, vertical))
  end

  -- Gauges stack across the bar: a column on a horizontal bar, a row on a side bar.
  local stack = if vertical then ui.row else ui.column
  barWidget.render(stack({ gap = GAP, align = "center", justify = "center" }, gauges))
  barWidget.setTooltip(tooltipRows())
  barWidget.setVisible(true)
end

local function load()
  local info = noctalia.fileInfo(statePath)
  if info == nil then
    -- No state yet (poller has not run): show nothing.
    if lastStamp ~= "missing" then
      lastStamp = "missing"
      accounts = {}
      render()
    end
    return
  end

  local stamp = tostring(info.mtime) .. ":" .. tostring(info.size)
  if stamp == lastStamp then
    return
  end

  local raw = noctalia.readFile(statePath)
  if raw == nil then
    return
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if not ok or type(data) ~= "table" then
    -- Partial read during a rewrite: keep the previous values and retry next tick.
    return
  end
  lastStamp = stamp
  accounts = if type(data.accounts) == "table" then data.accounts else {}
  render()
end

function update()
  load()
end

noctalia.setUpdateInterval(CHECK_INTERVAL_MS)
load()
if lastStamp == nil then
  -- Unreadable on the first try: start hidden rather than as an empty capsule.
  render()
end
