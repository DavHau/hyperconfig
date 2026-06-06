#!/usr/bin/env bash
# Migrate the Gosund SW9 from Tasmota to ESPHome over the air.
#
# Performs every safety step the ESPHome Tasmota-migration guide spells out for an
# ESP8266 with Tasmota 7.2+:
#
#   0. Pre-flight: verify the target really is the expected Tasmota device,
#      verify it's running Tasmota >= 8.2 (gz OTA support), download a fresh
#      config backup as a last-resort restore point.
#   1. SetOption78 1 (allow non-Tasmota OTA) + Restart, verify it stuck.
#   2. Compile firmware.bin from rolladen-wz.yaml.
#   3. gzip -9 the image (ESP8266 needs the compressed form to OTA-fit).
#   4. Upload to Tasmota's /u2 endpoint. Auto-detects whether the ESPHome image
#      fits in the running Tasmota's free OTA slot; if not (the common case
#      because release-tasmota itself is ~648 KB and the 1 MB build layout only
#      leaves ~350 KB free), does the "Indirect Method" — flashes
#      tasmota-minimal.bin.gz first, which frees the OTA slot, then flashes
#      ESPHome on the second pass.
#   5. Post-flight: wait for the device to come back as ESPHome.
#
# Aborts at the first failing step (set -euo pipefail). Safe to re-run after a
# failure: a failed OTA leaves Tasmota intact, because eboot only swaps the boot
# pointer after a fully verified write.
#
# Hard requirements: bash, curl, gzip, awk, nix (for `nix run nixpkgs#esphome`).

set -euo pipefail

# --- knobs (env-overridable) -----------------------------------------------
DEVICE_IP="${DEVICE_IP:-192.168.10.183}"
EXPECTED_HOSTNAME_PREFIX="${EXPECTED_HOSTNAME_PREFIX:-rolladen-WZ}"
ESPHOME_NAME="${ESPHOME_NAME:-rolladen-wz}"
TASMOTA_MINIMAL_URL="${TASMOTA_MINIMAL_URL:-http://ota.tasmota.com/tasmota/release/tasmota-minimal.bin.gz}"
# How much headroom (bytes) to require above the .gz size when deciding whether
# the upload fits directly. Tasmota's Update.begin reserves a few KB; 32 KB is
# a comfortable margin that avoids the "Nicht genug Speicherplatz" edge case.
FIT_MARGIN_BYTES="${FIT_MARGIN_BYTES:-32768}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML="${YAML:-$SCRIPT_DIR/$ESPHOME_NAME.yaml}"
SECRETS="${SECRETS:-$SCRIPT_DIR/secrets.yaml}"
BIN="$SCRIPT_DIR/.esphome/build/$ESPHOME_NAME/.pioenvs/$ESPHOME_NAME/firmware.bin"
MINIMAL_GZ="$SCRIPT_DIR/tasmota-minimal.bin.gz"

# --- helpers ---------------------------------------------------------------
log()  { printf '\n>>> %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Read one top-level scalar from secrets.yaml. Strips trailing comments and
# optional surrounding double-quotes. Returns empty if the key is absent.
secret() {
  awk -v k="$1" '
    $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$SECRETS"
}

# Issue a Tasmota /cm command. Echoes the response body; exits non-zero on
# HTTP error or transport failure (curl --fail).
cm() {
  curl --fail --silent --show-error --max-time 10 \
    --get "http://$DEVICE_IP/cm" \
    --data-urlencode "user=$TASMOTA_USER" \
    --data-urlencode "password=$TASMOTA_PASS" \
    --data-urlencode "cmnd=$1"
}

# Report current Tasmota OTA-slot free bytes (StatusMEM.Free * 1024). Echoes
# 0 + non-zero exit on parse failure.
tasmota_free_bytes() {
  local raw
  raw=$(cm "Status 4") || return 1   # StatusMEM
  local free_kb
  free_kb=$(grep -oE '"Free":[0-9]+' <<<"$raw" | head -n1 | cut -d: -f2)
  [[ -n "$free_kb" ]] || { echo 0; return 1; }
  echo "$((free_kb * 1024))"
}

# Wait for Tasmota /cm to respond again after a reboot/restart. Up to ${2:-120}s.
wait_for_tasmota() {
  local label=$1 timeout_s=${2:-120}
  log "waiting for $label to come back (up to ${timeout_s}s)"
  sleep 5
  local i
  for (( i = 0; i < timeout_s / 2; i++ )); do
    sleep 2
    if cm "Status" >/dev/null 2>&1; then
      printf '%s back after ~%ds\n' "$label" "$((5 + i * 2))"
      return 0
    fi
    printf .
  done
  printf '\n'
  die "$label did not come back within ${timeout_s}s"
}

# Upload a (.gz) firmware image to Tasmota /u2. Aborts on any reported error or
# missing success marker. On return, the device is rebooting — caller waits.
# Recognises both English and German Tasmota response strings.
upload_to_u2() {
  local file=$1 label=$2
  log "uploading $label ($(stat -c '%s' "$file") B) to Tasmota /u2"
  local resp
  resp=$(curl --fail --silent --show-error --max-time 180 \
              --user "$TASMOTA_USER:$TASMOTA_PASS" \
              --form "u2=@$file" \
              "http://$DEVICE_IP/u2") \
    || die "$label: HTTP upload request failed (Tasmota stayed in control; safe to re-run)"

  # Tasmota's response is HTML — extract just the human result text. The
  # interesting line lives inside a <b>...</b> in the result <div>.
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

# --- 0. pre-flight ---------------------------------------------------------
need curl
need gzip
need awk
need python3
need nix

[[ -f "$YAML"    ]] || die "ESPHome config not found: $YAML"
[[ -f "$SECRETS" ]] || die "secrets.yaml not found: $SECRETS"

TASMOTA_USER="${TASMOTA_USER:-$(secret tasmota_user)}"
TASMOTA_PASS="${TASMOTA_PASS:-$(secret tasmota_password)}"
[[ -n "$TASMOTA_USER" ]] || die "tasmota_user missing from secrets.yaml (or set TASMOTA_USER)"
[[ -n "$TASMOTA_PASS" ]] || die "tasmota_password missing from secrets.yaml (or set TASMOTA_PASS)"

log "Step 0/5: pre-flight — verifying target and backing up Tasmota config"
status=$(cm "Status 0") \
  || die "device $DEVICE_IP unreachable or rejected the request (already on ESPHome? wrong creds?)"
grep -q '"Version"' <<<"$status" \
  || die "response from $DEVICE_IP is not a Tasmota Status JSON"
grep -q "\"Hostname\":\"$EXPECTED_HOSTNAME_PREFIX" <<<"$status" \
  || die "device hostname does not start with '$EXPECTED_HOSTNAME_PREFIX' — refusing to flash the wrong device"

ver=$(grep -oE '"Version":"[^"]+"' <<<"$status" | head -n1 | cut -d'"' -f4)
major=$(grep -oE '^[0-9]+' <<<"$ver" || echo 0)
[[ "$major" -ge 8 ]] \
  || die "Tasmota $ver is older than 8.2 — gz OTA not supported; upgrade Tasmota first"
printf 'target ok: Tasmota %s, hostname prefix %s\n' "$ver" "$EXPECTED_HOSTNAME_PREFIX"

backup="$SCRIPT_DIR/Config_pre-esphome_$(date +%Y%m%dT%H%M%S).dmp"
curl --fail --silent --show-error --max-time 15 \
     --user "$TASMOTA_USER:$TASMOTA_PASS" \
     -o "$backup" "http://$DEVICE_IP/dl" \
  || die "Tasmota config backup failed; aborting before any irreversible step"
[[ -s "$backup" ]] || die "Tasmota config backup is empty"
printf 'backup saved: %s (%s bytes)\n' "$backup" "$(stat -c '%s' "$backup")"

# --- 1. SetOption78 --------------------------------------------------------
log "Step 1/5: enabling SetOption78 (allow non-Tasmota OTA)"
before=$(cm "SetOption78")
echo "before: $before"
if grep -q '"SetOption78":"OFF"' <<<"$before"; then
  set_resp=$(cm "SetOption78 1")
  echo "set:    $set_resp"
  grep -q '"SetOption78":"ON"' <<<"$set_resp" \
    || die "SetOption78 did not flip to ON"
  echo "restarting Tasmota so SetOption78 takes effect..."
  cm "Restart 1" >/dev/null
  wait_for_tasmota "Tasmota" 90
  after=$(cm "SetOption78")
  echo "after:  $after"
  grep -q '"SetOption78":"ON"' <<<"$after" \
    || die "SetOption78 didn't persist as ON after restart"
elif grep -q '"SetOption78":"ON"' <<<"$before"; then
  echo "SetOption78 already ON — no restart needed"
else
  die "unexpected SetOption78 response: $before"
fi

# --- 2. compile ------------------------------------------------------------
log "Step 2/5: compiling firmware from $YAML"
( cd "$SCRIPT_DIR" && nix run nixpkgs#esphome -- compile "$YAML" ) \
  || die "esphome compile failed"
[[ -f "$BIN" ]] || die "firmware.bin not produced at $BIN"
size=$(stat -c '%s' "$BIN")
printf 'firmware.bin = %s bytes\n' "$size"
# esp01_1m has a ~512 KiB sketch slot on ESPHome's own layout. Hard-cap here
# before we bother gzipping/uploading something the future ESPHome OTA path
# couldn't accept either.
[[ "$size" -lt 524288 ]] \
  || die "firmware.bin is >= 512 KiB; will not fit even ESPHome's own OTA slot"

# --- 3. gzip ---------------------------------------------------------------
log "Step 3/5: compressing to firmware.bin.gz"
gzip -9 -k -f "$BIN" || die "gzip failed"
GZ="$BIN.gz"
gsize=$(stat -c '%s' "$GZ")
printf 'firmware.bin.gz = %s bytes\n' "$gsize"

# --- 4. upload (with auto-detected 2-step if needed) -----------------------
log "Step 4/5: deciding upload path against Tasmota's free OTA slot"
free_now=$(tasmota_free_bytes) || die "could not read Tasmota free flash"
required=$(( gsize + FIT_MARGIN_BYTES ))
printf 'Tasmota free flash: %s B   ESPHome .gz: %s B   need: %s B (gz + %s B margin)\n' \
  "$free_now" "$gsize" "$required" "$FIT_MARGIN_BYTES"

if (( required > free_now )); then
  log "Step 4a/5: direct upload too tight — installing tasmota-minimal first"
  log "Downloading $TASMOTA_MINIMAL_URL"
  curl --fail --silent --show-error --max-time 60 \
       -o "$MINIMAL_GZ" "$TASMOTA_MINIMAL_URL" \
    || die "failed to download tasmota-minimal.bin.gz"

  # Sanity-check the downloaded image is actually an ESP8266 firmware before we
  # let Tasmota write it to flash. Tasmota's /u2 only checks magic byte 0xE9 /
  # 0x1F (gz), which an ESP32 image also satisfies — verifying entry point and
  # an embedded ESP8266 marker rules out a wrong-arch mirror serving us bricks.
  python3 - "$MINIMAL_GZ" <<'PY' || die "tasmota-minimal.bin.gz failed ESP8266 sanity check; refusing to flash"
import gzip, struct, sys
with gzip.open(sys.argv[1], 'rb') as f:
    hdr = f.read(8)
    body = f.read()
magic, _segments, _fm, _fs = hdr[0], hdr[1], hdr[2], hdr[3]
entry = struct.unpack('<I', hdr[4:8])[0]
if magic != 0xE9:
    sys.exit(f"bad magic 0x{magic:02x}")
# ESP8266 IRAM range; ESP32 firmware entries are in 0x4008xxxx.
if not (0x40100000 <= entry < 0x40140000):
    sys.exit(f"entry 0x{entry:08x} not in ESP8266 IRAM range")
if b"ESP8266" not in body:
    sys.exit("no ESP8266 marker found in image body")
print(f"OK: ESP8266 firmware, entry=0x{entry:08x}")
PY
  msize=$(stat -c '%s' "$MINIMAL_GZ")
  printf 'tasmota-minimal.bin.gz = %s bytes\n' "$msize"
  (( msize < free_now )) \
    || die "tasmota-minimal (${msize} B) also doesn't fit the current free slot (${free_now} B); cannot recover via OTA, need serial flash"

  upload_to_u2 "$MINIMAL_GZ" "tasmota-minimal"
  wait_for_tasmota "tasmota-minimal" 180

  # Confirm minimal is up. Its Status reports a "minimal" version suffix in
  # release-tasmota; we don't strictly require that, only that /cm answers.
  st=$(cm "Status 0")
  vmin=$(grep -oE '"Version":"[^"]+"' <<<"$st" | head -n1 | cut -d'"' -f4)
  echo "now running: $vmin"

  # Settings (including SetOption78) persist across the OTA, but re-arm if the
  # minimal build wiped it for any reason — it's required for the second upload.
  so78=$(cm "SetOption78" 2>/dev/null || true)
  if ! grep -q '"SetOption78":"ON"' <<<"$so78"; then
    log "re-enabling SetOption78 on tasmota-minimal"
    cm "SetOption78 1" >/dev/null
    cm "Restart 1" >/dev/null
    wait_for_tasmota "tasmota-minimal" 120
  fi

  free_after_min=$(tasmota_free_bytes) || die "could not re-read free flash on tasmota-minimal"
  printf 'tasmota-minimal free flash: %s B (was %s B before)\n' "$free_after_min" "$free_now"
  (( free_after_min >= required )) \
    || die "even tasmota-minimal doesn't free enough flash for ESPHome (need $required B, have $free_after_min B); refusing to continue"
fi

# Main event: flash ESPHome.
upload_to_u2 "$GZ" "ESPHome firmware"

# --- 5. post-flight --------------------------------------------------------
log "Step 5/5: waiting for the device to come back as ESPHome"
# Tasmota's /cm goes away on ESPHome; web_server returns regular HTML. We poll
# both: as soon as /cm stops returning Tasmota JSON AND / returns identifiable
# ESPHome HTML, we declare success.
sleep 15
ok=0
for i in $(seq 1 38); do  # up to ~91s after the 15s grace
  sleep 2
  cm_resp=$(curl --silent --max-time 2 \
                 --get "http://$DEVICE_IP/cm" \
                 --data-urlencode "cmnd=Status" 2>/dev/null || true)
  if [[ -n "$cm_resp" ]] && grep -q '"Version"' <<<"$cm_resp"; then
    continue  # still Tasmota
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
