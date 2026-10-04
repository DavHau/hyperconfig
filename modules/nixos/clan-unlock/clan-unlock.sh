usage() {
  echo "usage: clan-unlock <machine> [<host|ip> [port]]" >&2
  echo "  pipes <machine>'s disk passphrase from clan vars into its initrd's unlock" >&2
  echo "  without a host: its fixed link-local address, via the machine next to it" >&2
  exit 2
}

machine=${1:-}
[ -n "$machine" ] || usage
target "$machine" || {
  echo "clan-unlock: $machine has no hyper.unlockTarget" >&2
  exit 1
}
port=${3:-2222}
# Pinned keys first (read-only), then where first-use keys get recorded.
known="${XDG_STATE_HOME:-$HOME/.local/state}/clan-unlock.known_hosts $KNOWN_HOSTS"
jumpssh=(ssh -o ConnectTimeout=10 -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=yes)
# Set by target(): jump host, initrd address, passphrase var.
# shellcheck disable=SC2154
if [ -n "${2:-}" ]; then
  proxy=()
  dest=$2
else
  proxy=(-o "ProxyCommand=${jumpssh[*]} -W [%h]:%p root@$jump")
fi

# Which of the initrd's sshd and the booted system's answers, each probe
# bounded: a booted machine's firewall drops the initrd port silently, and a
# plain connect to it would hang for minutes. Run on the jump host when
# there is one (the link-local address is only reachable from its link).
# root's login shell may be fish, hence the explicit bash.
# shellcheck disable=SC2016 # expands in that bash, not here
probe='for p in "$1" 22; do
  if timeout 5 bash -c "exec 3<>/dev/tcp/$0/$p" 2>/dev/null; then echo "$p"; exit; fi
done
echo none'
if [ ${#proxy[@]} -eq 0 ]; then
  state=$(bash -c "$probe" "$dest" "$port")
else
  state=$("${jumpssh[@]}" "root@$jump" "bash -c '$probe' '$dest' '$port'") || {
    echo "clan-unlock: cannot reach $jump to get to $machine" >&2
    exit 1
  }
fi
case "$state" in
  "$port") ;;
  22)
    echo "clan-unlock: $machine is already booted (its ssh answers, the initrd's does not)" >&2
    exit 1
    ;;
  *)
    echo "clan-unlock: nothing answers at $dest: $machine is off, or its initrd has no network" >&2
    exit 1
    ;;
esac

flake=${CLAN_FLAKE:-/home/grmpf/synced/projects/hyperconfig}
passphrase=$(clan vars get --flake "$flake" "$machine" "$var")
if [ -z "$passphrase" ]; then
  echo "clan-unlock: no $var for $machine" >&2
  exit 1
fi

# The initrd sshd has its own host key; HostKeyAlias keeps one entry per
# machine whichever address reached it.
printf '%s' "$passphrase" | ssh \
  "${proxy[@]}" \
  -p "$port" \
  -o ConnectTimeout=10 \
  -o HostKeyAlias="$machine-initrd" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$known" \
  "root@$dest" \
  unlock
