#!/system/bin/sh
# Turn the Wi-Fi hotspot off when no client is connected (Dave's phone,
# docs/dave-phone.md). Needs the shell uid (TETHER_PRIVILEGED): run it via
# Shizuku's rish, or adb. Log: /data/local/tmp/hotspot-off-if-idle.log.
LOG=/data/local/tmp/hotspot-off-if-idle.log
ts() { date '+%F %T'; }
t=$(dumpsys tethering)
if ! printf '%s\n' "$t" | grep -qE '^ +(wlan[0-9]+|softap[0-9]+|ap_br_[a-z0-9_]+) - TetheredState'; then
  echo "$(ts) hotspot off, nothing to do" >> "$LOG"
else
  # "Client Information:" lists one block per tethered client, "<empty>" if none.
  n=$(printf '%s\n' "$t" | sed -n '/Client Information:/,/IPv4 Upstream/p' | grep -c 'TetheredClient\|MacAddress\|macAddress')
  if [ "$n" -eq 0 ]; then
    # ITetheringConnector.stopTethering(TETHERING_WIFI=0, callerPkg, tag, listener)
    service call tethering 5 i32 0 s16 com.android.shell s16 null >/dev/null 2>&1
    echo "$(ts) hotspot on, 0 clients: stopped" >> "$LOG"
  else
    echo "$(ts) hotspot on, clients connected: left on" >> "$LOG"
  fi
fi
tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
