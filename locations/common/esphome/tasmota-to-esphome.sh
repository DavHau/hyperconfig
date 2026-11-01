#!/usr/bin/env bash
# Migrate a Gosund SW9 from Tasmota to ESPHome over the air.
#
# Usage:
#   DEVICE_IP=<ip[:port]> TASMOTA_USER=<user> TASMOTA_PASS=<password> \
#     tasmota-to-esphome.sh <location>/esphome/<node>.yaml
# e.g.
#   DEVICE_IP=192.168.10.177 TASMOTA_USER=admin TASMOTA_PASS=... \
#     locations/common/esphome/tasmota-to-esphome.sh locations/playa/esphome/rolladen-sz.yaml
# Builds the given device config (which includes ./gosund-sw9.yaml as a package) and
# flashes DEVICE_IP. TASMOTA_USER / TASMOTA_PASS are the running Tasmota's web login.
# Everything per device stays next to that config: secrets.yaml (written from clan vars by
# ./esphome-secrets.sh), the .esphome/ build tree, the Tasmota config backup and the
# transient tasmota-minimal image.
# The file name must equal the node's `name` substitution (it locates the build output).
#
# Resumable. Detects starting state automatically:
#   - full Tasmota (e.g. release-tasmota-DE)  -> may need the 2-step path (see below)
#   - tasmota-minimal already installed       -> skip straight to ESPHome upload
#   - already on ESPHome                      -> nothing to do, exit clean
#
# What it does (per the ESPHome migration guide + Tasmota upgrade docs):
#   0. Pre-flight    : verify target reachable, identify mode, (full only) backup config.
#   1. Compile       : ESPHome firmware.bin from $YAML.
#   2. Compress      : gzip -9 -> firmware.bin.gz.
#   3. 2-step gate   : if running full Tasmota and ESPHome.gz + margin > free OTA slot,
#                      do the documented "Indirect Method": download tasmota-minimal.bin.gz,
#                      sanity-check it as an ESP8266 image, GET /up + POST /u2 to flash it,
#                      wait for reboot, then continue. (On a 1 MB Tasmota build the running
#                      sketch is ~648 KB and leaves only ~352 KB free; ESPHome at ~360 KB gz
#                      doesn't fit, hence the interlude.)
#   4. Upload ESPHome: GET /up (sets Web.upload_file_type = UPL_TASMOTA — this is required;
#                      a direct POST to /u2 silently falls through to Update.write() with the
#                      Updater never begin()-ed, returns 0, and Tasmota emits "Nicht genug
#                      Speicherplatz" despite Update.begin never having been reached),
#                      POST /u2 with the firmware, parse response, wait for reboot.
#   5. Post-flight   : poll until /cm stops answering as Tasmota AND the root page is ESPHome.
#
# Aborts at the first failing step (set -euo pipefail). A failed OTA leaves whichever Tasmota
# variant was running fully intact (eboot only swaps the boot pointer after a complete write),
# so re-running after a failure is safe.
#
# Note: SetOption78 was the old "allow non-Tasmota OTA" knob (~v7.2 era). In Tasmota 14 it is
# `ex_compatibility_check` in tasmota_types.h — deprecated, no longer referenced by the OTA
# upload path. The script does not touch it.
#
# Hard requirements: bash, curl, gzip, python3, nix (for `nix run nixpkgs#esphome`).

set -euo pipefail

# --- knobs (env-overridable) -----------------------------------------------
[[ $# -eq 1 ]] || { echo "usage: DEVICE_IP=<ip[:port]> $0 <device>.yaml" >&2; exit 2; }
YAML="$(realpath "$1")"
DEVICE_DIR="$(dirname "$YAML")"
ESPHOME_NAME="${ESPHOME_NAME:-$(basename "$YAML" .yaml)}"
DEVICE_IP="${DEVICE_IP:?set DEVICE_IP to the current device address, ip or host:port}"
# Safety guard: the running Tasmota hostname must start with this (case-insensitive) so we
# never flash the wrong box. Defaults to ESPHOME_NAME — Tasmota hostnames here are e.g.
# rolladen-WZ-5351 / rolladen-SZ-0154, a case-insensitive prefix of the node name.
EXPECTED_HOSTNAME_PREFIX="${EXPECTED_HOSTNAME_PREFIX:-$ESPHOME_NAME}"
TASMOTA_MINIMAL_URL="${TASMOTA_MINIMAL_URL:-http://ota.tasmota.com/tasmota/release/tasmota-minimal.bin.gz}"
# How much headroom (bytes) to require above the .gz size when deciding whether the
# direct upload fits. Tasmota's Update.begin reserves a few KB; 32 KB is a comfortable
# margin that avoids the "Nicht genug Speicherplatz" edge case at the boundary.
FIT_MARGIN_BYTES="${FIT_MARGIN_BYTES:-32768}"

SECRETS="${SECRETS:-$DEVICE_DIR/secrets.yaml}"
BIN="$DEVICE_DIR/.esphome/build/$ESPHOME_NAME/.pioenvs/$ESPHOME_NAME/firmware.bin"
MINIMAL_GZ="$DEVICE_DIR/tasmota-minimal.bin.gz"

# --- helpers ---------------------------------------------------------------
log()  { printf '\n>>> %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Issue a Tasmota /cm command. Echoes response body. On minimal builds, most commands
# return {"Command":"Unknown",...} — that is a valid HTTP 200, so callers must inspect
# the body, not just the exit code.
cm() {
  curl --fail --silent --show-error --max-time 10 \
    --get "http://$DEVICE_IP/cm" \
    --data-urlencode "user=$TASMOTA_USER" \
    --data-urlencode "password=$TASMOTA_PASS" \
    --data-urlencode "cmnd=$1"
}

# Report the running mode: full | minimal | esphome | absent.
# Detection: GET /cm?cmnd=Status 0 — full returns rich JSON with "Version", minimal
# returns {"Command":"Unknown",...}, ESPHome has no /cm endpoint and returns 404,
# unreachable devices fail the curl.
device_mode() {
  local body http
  body=$(curl --silent --max-time 6 --write-out '\n%{http_code}' \
              --get "http://$DEVICE_IP/cm" \
              --data-urlencode "user=$TASMOTA_USER" \
              --data-urlencode "password=$TASMOTA_PASS" \
              --data-urlencode "cmnd=Status 0" 2>/dev/null || true)
  http="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [[ -z "$http" || "$http" == 000 ]]; then echo absent; return; fi
  if [[ "$http" == 404 ]]; then echo esphome; return; fi
  if [[ "$http" == 200 ]]; then
    if   grep -q '"Version"'              <<<"$body"; then echo full
    elif grep -qi '"Command":"Unknown"'   <<<"$body"; then echo minimal
    else echo esphome  # /cm answered 200 but not Tasmota shape -> ESPHome web_server
    fi
    return
  fi
  echo absent
}

# Free OTA-slot bytes on full Tasmota (StatusMEM.Free * 1024). Only valid in 'full' mode.
tasmota_free_bytes() {
  local raw free_kb
  raw=$(cm "Status 4") || return 1
  free_kb=$(grep -oE '"Free":[0-9]+' <<<"$raw" | head -n1 | cut -d: -f2)
  [[ -n "$free_kb" ]] || { echo 0; return 1; }
  echo "$((free_kb * 1024))"
}

# Wait for /cm to answer Tasmota-ish again after a reboot/restart. Up to ${2:-120}s.
# "Tasmota-ish" = JSON body (either rich Status JSON, or minimal's `{"Command":"Unknown",...}`).
wait_for_tasmota() {
  local label=$1 timeout_s=${2:-120}
  log "waiting for $label to come back (up to ${timeout_s}s)"
  sleep 5
  local i body
  for (( i = 0; i < timeout_s / 2; i++ )); do
    sleep 2
    body=$(curl --silent --max-time 3 --get "http://$DEVICE_IP/cm" \
                --data-urlencode "user=$TASMOTA_USER" \
                --data-urlencode "password=$TASMOTA_PASS" \
                --data-urlencode "cmnd=Status" 2>/dev/null || true)
    if [[ -n "$body" ]] && grep -qE '"Version"|"Command":"Unknown"' <<<"$body"; then
      printf '%s back after ~%ds\n' "$label" "$((5 + i * 2))"
      return 0
    fi
    printf .
  done
  printf '\n'
  die "$label did not come back within ${timeout_s}s"
}

# Upload a .gz firmware image to Tasmota /u2. CRITICAL: GET /up first to set
# Web.upload_file_type = UPL_TASMOTA — without it the upload silently fails
# (Updater never begin()'d, Update.write returns 0, error 2 "Nicht genug
# Speicherplatz"). Bilingual response parsing (English + German). On return,
# the device is rebooting and the caller waits.
upload_to_u2() {
  local file=$1 label=$2 fsz
  fsz=$(stat -c '%s' "$file")
  log "uploading $label ($fsz B) to Tasmota /u2"

  # 1. GET /up to render the upgrade form. This SETS Web.upload_file_type = UPL_TASMOTA
  #    inside the (running) Tasmota's state. The variable persists between requests; the
  #    subsequent POST /u2 will see it. (Tested with curl --user; basic auth re-applied.)
  curl --fail --silent --show-error --max-time 10 \
       --user "$TASMOTA_USER:$TASMOTA_PASS" \
       -o /dev/null "http://$DEVICE_IP/up" \
    || die "$label: GET /up failed (could not arm Tasmota upload state)"

  # 2. POST /u2 with the firmware. The ?fsz=N is the same hint the web UI sends; harmless
  #    on ESP8266 (only consumed by the log line), but matches the browser flow exactly.
  local resp
  resp=$(curl --fail --silent --show-error --max-time 180 \
              --user "$TASMOTA_USER:$TASMOTA_PASS" \
              --form "u2=@$file" \
              "http://$DEVICE_IP/u2?fsz=$fsz") \
    || die "$label: HTTP upload request failed (Tasmota stayed in control; safe to re-run)"

  # Extract the human result text from the HTML body (the result line lives in <b>...</b>).
  local extracted
  extracted=$(printf '%s' "$resp" \
    | sed 's/<[^>]*>/\n/g' \
    | tr -s '[:space:]' '\n' \
    | grep -iE 'upload|successful|fail|fehlge|erfolg|neustart|restart|reboot|speicher|space|error|fehler' \
    | head -8 || true)
  if [[ -n "$extracted" ]]; then
    printf 'Tasmota response (extracted): %s\n' "$(printf '%s ' "$extracted")"
  else
    printf 'Tasmota response (raw, head): %s\n' "$(printf '%s' "$resp" | head -c 200)"
  fi

  # Failure detection — both languages.
  if grep -qiE 'fehlgeschlagen|nicht genug speicher|fehler|upload error|error code|failed|failure|not enough' <<<"$resp"; then
    die "$label: Tasmota reported an upload error — flash did not take, Tasmota is still in control"
  fi
  # Success marker — both languages.
  grep -qiE 'erfolgreich|neustart|upload successful|successful|restart|rebooting' <<<"$resp" \
    || die "$label: no success marker in Tasmota response; refusing to claim flash succeeded"
}

# Verify a downloaded .gz is really an ESP8266 firmware. Tasmota's /u2 only checks
# magic byte 0xE9 / 0x1F (gz), which an ESP32 image also satisfies — this rules out
# a wrong-arch mirror by also checking the entry point lies in ESP8266 IRAM and that
# the body contains the explicit "ESP8266" marker that Tasmota's source embeds.
verify_esp8266_image() {
  python3 - "$1" <<'PY' || return 1
import gzip, struct, sys
with gzip.open(sys.argv[1], 'rb') as f:
    hdr = f.read(8); body = f.read()
magic = hdr[0]
entry = struct.unpack('<I', hdr[4:8])[0]
if magic != 0xE9:
    sys.exit(f"bad magic 0x{magic:02x}")
if not (0x40100000 <= entry < 0x40140000):  # ESP8266 IRAM; ESP32 is 0x4008xxxx
    sys.exit(f"entry 0x{entry:08x} not in ESP8266 IRAM range")
if b"ESP8266" not in body:
    sys.exit("no ESP8266 marker found in image body")
print(f"OK: ESP8266 firmware, entry=0x{entry:08x}")
PY
}

# Check that secrets.yaml's wifi_ssid/wifi_password are a pair the running Tasmota uses.
# A wrong pair bricks the unit remotely: ESPHome comes up, never joins, and only someone
# on site can reach its fallback AP. Tasmota's /dl dump is XOR-obfuscated (byte i ^=
# 0x5A + i, from i = 2); its settings text pool stores STASSID1, STASSID2, STAPWD1,
# STAPWD2 back to back as NUL-terminated strings, so a password sits two entries after
# its SSID. esphome-secrets.sh writes every value as a JSON string (a YAML double-quoted
# scalar), so json.loads reads it back exactly.
verify_wifi_in_backup() {
  python3 - "$1" "$SECRETS" <<'PY'
import json, re, sys
buf = bytearray(open(sys.argv[1], "rb").read())
for i in range(2, len(buf)):
    buf[i] ^= (0x5A + i) & 0xFF
secrets = {
    m[1]: json.loads(m[2])
    for m in re.finditer(r'^(\w+): (".*")$', open(sys.argv[2], encoding="utf-8").read(), re.M)
}
ssid, pw = secrets.get("wifi_ssid", "").encode(), secrets.get("wifi_password", "").encode()
if not ssid or not pw:
    sys.exit("wifi_ssid / wifi_password missing from secrets.yaml")
strings = bytes(buf).split(b"\0")
for k, s in enumerate(strings[:-2]):
    if s == ssid:
        if strings[k + 2] == pw:
            print(f"OK: Tasmota joins {ssid.decode()} with the password in secrets.yaml")
            sys.exit(0)
        sys.exit(f"Tasmota's password for {ssid.decode()} differs from secrets.yaml wifi_password")
sys.exit(f"Tasmota has no stored network {ssid.decode()} (secrets.yaml wifi_ssid)")
PY
}

# --- 0. pre-flight ---------------------------------------------------------
need curl
need gzip
need python3
need nix

[[ -f "$YAML"    ]] || die "ESPHome config not found: $YAML"
[[ -f "$SECRETS" ]] || die "secrets.yaml not found: $SECRETS (write it with $(dirname "$0")/esphome-secrets.sh)"

[[ -n "${TASMOTA_USER:-}" ]] || die "set TASMOTA_USER to the running Tasmota's web user"
[[ -n "${TASMOTA_PASS:-}" ]] || die "set TASMOTA_PASS to the running Tasmota's web password"

log "Step 0/5: pre-flight"
MODE=$(device_mode)
echo "device at $DEVICE_IP is running: $MODE"

case "$MODE" in
  absent)
    die "device $DEVICE_IP not reachable on the network (wrong IP, off, wrong WiFi?)"
    ;;
  esphome)
    log "Already running ESPHome. Nothing to migrate. Use 'esphome run $YAML' for further updates."
    exit 0
    ;;
  full)
    status=$(cm "Status 0")
    host=$(grep -oE '"Hostname":"[^"]+"' <<<"$status" | head -n1 | cut -d'"' -f4)
    [[ "${host,,}" == "${EXPECTED_HOSTNAME_PREFIX,,}"* ]] \
      || die "device hostname '$host' does not start with '$EXPECTED_HOSTNAME_PREFIX' — refusing to flash the wrong device"
    ver=$(grep -oE '"Version":"[^"]+"' <<<"$status" | head -n1 | cut -d'"' -f4)
    major=$(grep -oE '^[0-9]+' <<<"$ver" || echo 0)
    [[ "$major" -ge 8 ]] \
      || die "Tasmota $ver is older than 8.2 — gz OTA not supported; upgrade Tasmota first"
    printf 'target ok: Tasmota %s, hostname prefix %s\n' "$ver" "$EXPECTED_HOSTNAME_PREFIX"

    # Backup config — only available on full Tasmota; minimal strips /dl.
    backup="$DEVICE_DIR/Config_${ESPHOME_NAME}_pre-esphome_$(date +%Y%m%dT%H%M%S).dmp"
    curl --fail --silent --show-error --max-time 15 \
         --user "$TASMOTA_USER:$TASMOTA_PASS" \
         -o "$backup" "http://$DEVICE_IP/dl" \
      || die "Tasmota config backup failed; aborting before any irreversible step"
    [[ -s "$backup" ]] || die "Tasmota config backup is empty"
    printf 'backup saved: %s (%s bytes)\n' "$backup" "$(stat -c '%s' "$backup")"
    if [[ "${SKIP_WIFI_CHECK:-0}" != 1 ]]; then
      verify_wifi_in_backup "$backup" \
        || die "Wi-Fi credentials unverified; fix the clan vars esphome-<loc>/wifi_* and re-run esphome-secrets.sh (SKIP_WIFI_CHECK=1 if the unit moves networks)"
    fi
    ;;
  minimal)
    # /dl, Status N, and most commands are stripped in minimal builds; we can't introspect
    # further. The only thing we still need is /up + /u2, and both work.
    printf 'already on tasmota-minimal — backup, version and Wi-Fi checks skipped (not supported by minimal)\n'
    printf 'will go straight to the ESPHome upload after compile+gzip.\n'
    ;;
esac

# --- 1. compile ------------------------------------------------------------
log "Step 1/5: compiling firmware from $YAML"
( cd "$DEVICE_DIR" && nix run nixpkgs#esphome -- compile "$YAML" ) \
  || die "esphome compile failed"
[[ -f "$BIN" ]] || die "firmware.bin not produced at $BIN"
size=$(stat -c '%s' "$BIN")
printf 'firmware.bin = %s bytes\n' "$size"
# esp01_1m gives ~512 KiB sketch slot on ESPHome's own layout. Hard-cap here before we
# bother gzipping/uploading something the future ESPHome OTA path couldn't accept either.
[[ "$size" -lt 524288 ]] \
  || die "firmware.bin is >= 512 KiB; will not fit even ESPHome's own OTA slot"

# --- 2. gzip ---------------------------------------------------------------
log "Step 2/5: compressing to firmware.bin.gz"
gzip -9 -k -f "$BIN" || die "gzip failed"
GZ="$BIN.gz"
gsize=$(stat -c '%s' "$GZ")
printf 'firmware.bin.gz = %s bytes\n' "$gsize"

# --- 3. 2-step gate (only if full Tasmota AND the direct upload won't fit) -
log "Step 3/5: deciding upload path"
need_two_step=0
if [[ "$MODE" == "full" ]]; then
  free_now=$(tasmota_free_bytes) || die "could not read Tasmota free flash"
  required=$(( gsize + FIT_MARGIN_BYTES ))
  printf 'Tasmota free flash: %s B   ESPHome .gz: %s B   need: %s B (gz + %s B margin)\n' \
    "$free_now" "$gsize" "$required" "$FIT_MARGIN_BYTES"
  if (( required > free_now )); then
    need_two_step=1
  fi
else
  printf 'already on tasmota-minimal — 2-step interlude not needed\n'
fi

if (( need_two_step == 1 )); then
  log "Step 3a/5: direct upload too tight — installing tasmota-minimal first"
  log "Downloading $TASMOTA_MINIMAL_URL"
  curl --fail --silent --show-error --max-time 60 \
       -o "$MINIMAL_GZ" "$TASMOTA_MINIMAL_URL" \
    || die "failed to download tasmota-minimal.bin.gz"
  verify_esp8266_image "$MINIMAL_GZ" \
    || die "tasmota-minimal.bin.gz failed ESP8266 sanity check; refusing to flash"
  msize=$(stat -c '%s' "$MINIMAL_GZ")
  printf 'tasmota-minimal.bin.gz = %s bytes\n' "$msize"
  (( msize < free_now )) \
    || die "tasmota-minimal (${msize} B) also doesn't fit the current free slot (${free_now} B); cannot recover via OTA, need serial flash"

  upload_to_u2 "$MINIMAL_GZ" "tasmota-minimal"
  wait_for_tasmota "tasmota-minimal" 180

  # Re-detect mode — must be 'minimal' now, not 'full'. (If somehow still 'full', the
  # OTA didn't take and we're in a weird half-state; bail rather than continue blindly.)
  POST_MIN_MODE=$(device_mode)
  echo "post-minimal mode: $POST_MIN_MODE"
  [[ "$POST_MIN_MODE" == "minimal" ]] \
    || die "after the tasmota-minimal upload the device reports mode=$POST_MIN_MODE; expected 'minimal'"
fi

# --- 4. upload ESPHome ----------------------------------------------------
log "Step 4/5: uploading ESPHome firmware"
upload_to_u2 "$GZ" "ESPHome firmware"

# --- 5. post-flight --------------------------------------------------------
log "Step 5/5: waiting for the device to come back as ESPHome"
# Tasmota's /cm goes away on ESPHome; web_server returns plain HTML. We poll both:
# as soon as /cm stops returning Tasmota-shape JSON AND / returns identifiable ESPHome
# HTML, we declare success.
sleep 15
ok=0
for i in $(seq 1 38); do  # up to ~91s after the 15s grace
  sleep 2
  cm_resp=$(curl --silent --max-time 2 \
                 --get "http://$DEVICE_IP/cm" \
                 --data-urlencode "cmnd=Status" 2>/dev/null || true)
  if [[ -n "$cm_resp" ]] && grep -qE '"Version"|"Command":"Unknown"' <<<"$cm_resp"; then
    continue  # still Tasmota / tasmota-minimal
  fi
  root=$(curl --silent --max-time 2 "http://$DEVICE_IP/" 2>/dev/null || true)
  if grep -qiE "esphome|$ESPHOME_NAME" <<<"$root"; then
    printf 'ESPHome is alive at http://%s/ (after ~%ds)\n' "$DEVICE_IP" "$((15 + i * 2))"
    ok=1
    break
  fi
done

if [[ "$ok" -ne 1 ]]; then
  log "Could not positively confirm ESPHome on $DEVICE_IP within ~90s."
  log "Things to check before assuming a bad flash:"
  log "  - mDNS:   http://$ESPHOME_NAME.local/"
  log "  - DHCP:   the router may have given it a different IP"
  log "  - boot-loop: safe_mode kicks in after 10 failed boots (5 min window)"
  exit 1
fi

log "Migration complete."
