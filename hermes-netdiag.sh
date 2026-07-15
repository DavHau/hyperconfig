#!/usr/bin/env bash
# Hermes ↔ Telegram network diagnostic. Run: sudo bash /tmp/hermes-netdiag.sh
# Read-only. Safe. Paste the whole output back.
C=hermes-agent
HOST=api.telegram.org
V4_DC=149.154.167.220     # a Telegram DC IPv4
line(){ printf '\n========== %s ==========\n' "$*"; }
# container exec helper (rootful docker via sudo)
dex(){ timeout 25 docker exec "$C" sh -c "$*" 2>&1; }

line "0. docker + container status"
docker ps --filter "name=$C" --format '{{.Names}} {{.Status}}' 2>&1
echo "network mode:"; docker inspect -f '{{.HostConfig.NetworkMode}}' "$C" 2>&1
echo "container IPv6 enabled (sysctl disable_ipv6, 0=enabled):"
dex 'cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null; cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null'

line "1. container /etc/resolv.conf"
dex 'cat /etc/resolv.conf'
line "1b. container /etc/hosts + gai.conf + nsswitch"
dex 'echo "--hosts--"; cat /etc/hosts; echo "--gai.conf--"; grep -v "^#" /etc/gai.conf 2>/dev/null | grep -v "^$" || echo "(none)"; echo "--nsswitch hosts--"; grep "^hosts" /etc/nsswitch.conf 2>/dev/null'

line "2. container DNS resolution (timed)"
dex 'echo "--v4--"; time getent ahostsv4 '"$HOST"'; echo "--v6--"; time getent ahostsv6 '"$HOST"'; echo "--any--"; time getent ahosts '"$HOST"''

line "3. container connectivity to Telegram"
echo "--- curl present? ---"; dex 'command -v curl || echo NO-CURL'
echo "--- curl default (happy-eyeballs), 15s cap ---"
dex 'command -v curl >/dev/null && curl -sS -o /dev/null -w "default connect=%{time_connect} http=%{http_code}\n" --max-time 15 https://'"$HOST"'/ || echo skip'
echo "--- curl -4, 15s cap ---"
dex 'command -v curl >/dev/null && curl -4 -sS -o /dev/null -w "v4 connect=%{time_connect} http=%{http_code}\n" --max-time 15 https://'"$HOST"'/ || echo skip'
echo "--- curl -6, 15s cap ---"
dex 'command -v curl >/dev/null && curl -6 -sS -o /dev/null -w "v6 connect=%{time_connect} http=%{http_code}\n" --max-time 15 https://'"$HOST"'/ || echo skip'

line "4. container raw TCP (bash /dev/tcp, 10s each)"
dex 'timeout 10 bash -c "exec 3<>/dev/tcp/'"$V4_DC"'/443" && echo "v4 DC '"$V4_DC"':443 OK" || echo "v4 DC '"$V4_DC"':443 FAIL/hang"'

line "5. container python getaddrinfo + per-address connect (THE KEY TEST)"
# tries each resolved address in order, 8s timeout each -> shows which family the
# app picks and whether a connect HANGS (8s) vs instant-fails.
dex 'PY=$(command -v python3 || command -v python); [ -n "$PY" ] || { echo NO-PYTHON; exit 0; }; "$PY" - <<PYEOF
import socket, time
try:
    ai = socket.getaddrinfo("'"$HOST"'", 443, type=socket.SOCK_STREAM)
except Exception as e:
    print("getaddrinfo FAILED:", e); raise SystemExit
print("order returned by resolver:")
for fam,_,_,_,sa in ai:
    print("  ", "v6" if fam==socket.AF_INET6 else "v4", sa)
for fam,_,_,_,sa in ai:
    fn="v6" if fam==socket.AF_INET6 else "v4"
    s=socket.socket(fam, socket.SOCK_STREAM); s.settimeout(8); t=time.time()
    try:
        s.connect(sa); print(fn, sa, "CONNECT-OK", round(time.time()-t,2),"s")
    except Exception as e:
        print(fn, sa, "CONNECT-FAIL", round(time.time()-t,2),"s", type(e).__name__, e)
    finally:
        s.close()
PYEOF'

line "6. container IPv6 addr/route (why v6 connect behaves as it does)"
dex 'if command -v ip >/dev/null; then echo "--v6 addr--"; ip -6 addr show scope global; echo "--v6 route--"; ip -6 route; else echo "(no iproute2) /proc/net/ipv6_route:"; cat /proc/net/ipv6_route; fi'

line "7. container Telegram/proxy env the adapter sees"
dex 'env | grep -Ei "telegram|gateway|proxy|ipv|prefer" | sed -E "s/(TOKEN|KEY|SECRET)=.*/\1=<redacted>/I"'

line "8. HOST comparison (same netns)"
echo "--host v6 route--"; ip -6 route 2>&1 | head
echo "--host resolv.conf--"; cat /etc/resolv.conf
echo "--host curl -4/-6--"
curl -4 -sS -o /dev/null -w "host v4 connect=%{time_connect} http=%{http_code}\n" --max-time 12 https://$HOST/ 2>&1
curl -6 -sS -o /dev/null -w "host v6 connect=%{time_connect} http=%{http_code}\n" --max-time 12 https://$HOST/ 2>&1

line "DONE"
