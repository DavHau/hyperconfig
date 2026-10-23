--!nonstrict
-- Voice indicator bar widget. Tracks voxtype's lifecycle through its state file
-- at $XDG_RUNTIME_DIR/voxtype/state. voxtype rewrites the file (truncate in
-- place) on every transition: idle, recording, transcribing, streaming. A
-- missing or unreadable file means the daemon is down.
--
-- Plugins get no file watcher, so update() polls the file with readFileAsync:
-- slowly at rest, fast while a take is live so a quick recording ->
-- transcribing -> idle sequence is not collapsed into recording -> idle (which
-- would raise a false no-speech warning). The fast cadence also drives the
-- breathing animations, since the bar has no frame tick.

local KNOWN = { idle = true, recording = true, transcribing = true, streaming = true }
local DEFAULT_TOGGLE = "spaces-voice-record-toggle"

local REST_POLL_MS = 200
local LIVE_POLL_MS = 60
local PULSE_PERIOD_MS = 1400 -- 700 ms each way, as in v4
local LOADER_PERIOD_MS = 1000 -- v4 spun the loader once per second
local DIM_OPACITY = 0.4

local function trim(s: string): string
  return string.match(s, "^%s*(.-)%s*$") or ""
end

-- Settings (widgets are rebuilt when a plugin setting changes, so reading once
-- at load is enough).

local function configString(key: string, fallback: string): string
  local v = noctalia.getConfig(key)
  if type(v) == "string" then
    local t = trim(v)
    if t ~= "" then
      return t
    end
  end
  return fallback
end

local function configNumber(key: string, fallback: number): number
  local v = noctalia.getConfig(key)
  if type(v) == "number" and v == v then
    return v
  end
  return fallback
end

local toggleCommand = configString("toggle_command", DEFAULT_TOGGLE)
local hideWhenIdle = noctalia.getConfig("hide_when_idle") == true
local pulseEnabled = noctalia.getConfig("pulse") ~= false
local warningMs = configNumber("no_speech_warning_ms", 4000)
if warningMs <= 0 then
  warningMs = 4000
end
warningMs = math.round(warningMs)
local pulseIntensity = math.clamp(configNumber("pulse_intensity", 0.55), 0, 1)

-- Lifecycle state.

-- voxtype's lifecycle word, or "down" when the daemon is not running.
local voiceState = "down"
-- Set when a recording ends without ever transcribing: voxtype's energy VAD
-- rejected a silent or too-quiet take before transcription and stepped
-- straight from recording to idle. Cleared by the next take or after
-- warningMs.
local noSpeechWarning = false
local warningDeadlineMs = 0

-- Applies a new lifecycle word. The classification keys off the *previous*
-- word: a real take goes recording -> transcribing -> idle, a rejected one
-- recording -> idle, and a daemon dying mid-recording goes recording -> down;
-- only the second raises the warning.
local function setVoiceState(cur: string, nowMs: number)
  local prev = voiceState
  if prev == cur then
    return
  end
  if cur == "recording" or cur == "transcribing" or cur == "streaming" then
    noSpeechWarning = false
  elseif cur == "idle" and prev == "recording" then
    noSpeechWarning = true
    warningDeadlineMs = nowMs + warningMs
  end
  voiceState = cur
end

-- An unknown or empty word (a read racing voxtype's truncate, or a future
-- state word) keeps the previous state.
local function applyContents(raw: string, nowMs: number)
  local word = trim(raw)
  if KNOWN[word] then
    setVoiceState(word, nowMs)
  end
end

local function expireWarning(nowMs: number)
  if noSpeechWarning and nowMs >= warningDeadlineMs then
    noSpeechWarning = false
  end
end

-- State file location.

local statePath: string? = nil
local uidProbeStarted = false

local function setRuntimeDir(dir: string)
  statePath = dir .. "/voxtype/state"
end

do
  local dir = noctalia.getenv("XDG_RUNTIME_DIR")
  if type(dir) == "string" and dir ~= "" then
    setRuntimeDir(dir)
  end
end

-- Defensive fallback for a launch without XDG_RUNTIME_DIR (never the case under
-- a systemd user service): derive /run/user/$UID once.
local function resolveRuntimeDir()
  if statePath ~= nil or uidProbeStarted then
    return
  end
  uidProbeStarted = true
  noctalia.runAsync("id -u", function(result)
    local uid = trim(result.stdout or "")
    if result.exitCode == 0 and uid ~= "" then
      setRuntimeDir("/run/user/" .. uid)
    end
  end)
end

-- Presentation.

local shownApplied: boolean? = nil
local tooltipApplied: string? = nil
local intervalApplied: number? = nil
local treeApplied: string? = nil

local function isRecording(): boolean
  return voiceState == "recording" or voiceState == "streaming"
end

local function isLive(): boolean
  return isRecording() or voiceState == "transcribing"
end

-- 1 at the start of each period, easing (cosine, like InOutSine) down to 0 at
-- the half period and back.
local function wave(nowMs: number, periodMs: number): number
  return 0.5 + 0.5 * math.cos(2 * math.pi * (nowMs % periodMs) / periodMs)
end

local function setInterval(ms: number)
  -- setUpdateInterval restarts the host timer, so only call it on a change.
  if intervalApplied ~= ms then
    intervalApplied = ms
    noctalia.setUpdateInterval(ms)
  end
end

local function present(nowMs: number)
  expireWarning(nowMs)

  local shown = voiceState ~= "down" and (not (voiceState == "idle" and hideWhenIdle) or noSpeechWarning)
  if shownApplied ~= shown then
    shownApplied = shown
    barWidget.setVisible(shown)
  end

  setInterval(isLive() and LIVE_POLL_MS or REST_POLL_MS)

  if not shown then
    return
  end

  -- The warning wins over the idle colour (it only ever fires at idle).
  -- tertiary is the caution tone, distinct from recording red (error) and the
  -- transcribing accent (primary).
  local glyph = "microphone"
  local color = "on_surface_variant"
  local glyphOpacity = 1
  local glowAlpha = 0
  local tooltipKey = "voice.tooltip-idle"
  if noSpeechWarning then
    color = "tertiary"
    tooltipKey = "voice.tooltip-no-speech"
  elseif isRecording() then
    color = "error"
    tooltipKey = "voice.tooltip-recording"
    local w = wave(nowMs, PULSE_PERIOD_MS)
    glyphOpacity = DIM_OPACITY + (1 - DIM_OPACITY) * w
    if pulseEnabled then
      -- The glow breathes against the glyph: bright while the mic dims.
      glowAlpha = pulseIntensity * (DIM_OPACITY + (1 - DIM_OPACITY) * (1 - w))
    end
  elseif voiceState == "transcribing" then
    glyph = "loader-2"
    color = "primary"
    tooltipKey = "voice.tooltip-transcribing"
    glyphOpacity = DIM_OPACITY + (1 - DIM_OPACITY) * wave(nowMs, LOADER_PERIOD_MS)
  end

  if tooltipApplied ~= tooltipKey then
    tooltipApplied = tooltipKey
    barWidget.setTooltip(noctalia.tr(tooltipKey))
  end

  local fill = string.format("error/%.3f", glowAlpha)
  local opacity = string.format("%.3f", glyphOpacity)
  local signature = table.concat({ glyph, color, opacity, fill }, "|")
  if treeApplied == signature then
    return
  end
  treeApplied = signature
  -- The fill is always present (alpha 0 at rest) so the retained tree keeps
  -- the same shape and size in every state.
  barWidget.render(ui.row({ fill = fill, radius = 8, padding = 2, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, color = color, opacity = tonumber(opacity) }),
  }))
end

-- Polling.

local readPending = false

local function poll()
  if statePath == nil then
    resolveRuntimeDir()
    setVoiceState("down", noctalia.nowMs())
    return
  end
  if readPending then
    return
  end
  readPending = noctalia.readFileAsync(statePath, function(contents, _err)
    readPending = false
    local nowMs = noctalia.nowMs()
    if contents == nil then
      setVoiceState("down", nowMs)
    else
      applyContents(contents, nowMs)
    end
    present(nowMs)
  end)
end

function update()
  poll()
  present(noctalia.nowMs())
end

function onClick()
  noctalia.runAsync(toggleCommand)
end

present(noctalia.nowMs())
poll()
