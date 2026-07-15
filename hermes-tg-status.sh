#!/usr/bin/env bash
# Is hermes actually connected to Telegram? Run: sudo bash hermes-tg-status.sh
# Read-only. Paste the whole output back.
C=hermes-agent
STATE=/var/lib/hermes
LOGS="$STATE/.hermes/logs"
line(){ printf '\n========== %s ==========\n' "$*"; }

line "1. INFO-level truth from agent.log (journal only shows WARNING+)"
# The 'Connected to Telegram (polling mode)' line is INFO -> not in journalctl.
for f in agent.log gateway.log; do
  if [ -f "$LOGS/$f" ]; then
    echo "----- $LOGS/$f (last telegram/connect lines) -----"
    grep -aiE "telegram|connected to|polling|webhook|failed to connect|not authorized|dropp|traceback" "$LOGS/$f" | tail -40
  else
    echo "(no $LOGS/$f)"
  fi
done

line "2. any python traceback near the end of agent.log"
[ -f "$LOGS/agent.log" ] && tail -120 "$LOGS/agent.log" | grep -aiE "Traceback|Error|Exception|telegram" | tail -30

line "3. recent journal"
journalctl -u hermes-agent -n 25 --no-pager 2>&1 | tail -25

line "4. is the bot actually polling? live python stack (polling=idle in updater; wedged=blocked in lock/recv/dns)"
PID=$(docker top "$C" -eo pid,cmd 2>/dev/null | awk '/[p]ython/{print $1; exit}')
echo "hermes python host PID: ${PID:-<none found>}"
docker top "$C" -eo pid,cmd 2>/dev/null | grep -iE "python|PID" | head
if [ -n "$PID" ]; then
  echo "--- py-spy dump (fetches py-spy via nix; ~1 min first time) ---"
  timeout 120 nix run nixpkgs#py-spy -- dump --pid "$PID" 2>&1 | head -120 \
    || echo "py-spy unavailable/failed"
fi

line "5. quick token liveness (getMe) — proves token, no poll conflict"
TOKEN=$(docker exec "$C" sh -c 'sed -n "s/^TELEGRAM_BOT_TOKEN=//p" "$HERMES_HOME/.env"' 2>/dev/null)
if [ -n "$TOKEN" ]; then
  curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/getMe" | head -c 400; echo
  echo "--- getWebhookInfo (pending_update_count / last_error tell you a lot) ---"
  curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | head -c 600; echo
else
  echo "(could not read token from container .env)"
fi

line "DONE"
