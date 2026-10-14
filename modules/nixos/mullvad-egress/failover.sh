# Usage: mullvad-egress-failover IFACE PUBKEY ENDPOINT [PUBKEY ENDPOINT]...
# Moves the tunnel to the next relay of the list once the current peer has
# gone quiet. With PersistentKeepalive a live peer re-handshakes every two
# minutes, so none (or none for five minutes) means the relay is gone.
iface=$1
shift
keys=()
endpoints=()
while [ $# -ge 2 ]; do
  keys+=("$1")
  endpoints+=("$2")
  shift 2
done

current="" handshake=0
read -r current handshake < <(wg show "$iface" latest-handshakes) || true
age=$(($(date +%s) - handshake))
if [ "$handshake" -ne 0 ] && [ "$age" -lt 300 ]; then
  exit 0
fi

next=0
for i in "${!keys[@]}"; do
  if [ "${keys[$i]}" = "$current" ]; then
    next=$(((i + 1) % ${#keys[@]}))
  fi
done

echo "no recent handshake with ${current:-any peer}; switching to ${endpoints[$next]}"
args=()
[ -n "$current" ] && args+=(peer "$current" remove)
wg set "$iface" "${args[@]}" peer "${keys[$next]}" endpoint "${endpoints[$next]}" \
  allowed-ips 0.0.0.0/0,::/0 persistent-keepalive 25
