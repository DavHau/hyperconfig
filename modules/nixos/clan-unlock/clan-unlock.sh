usage() {
  echo "usage: clan-unlock <machine> <host|ip> [port]" >&2
  echo "  reads <machine>'s zfs-key from clan vars and loads it in its initrd" >&2
  exit 2
}

machine=${1:-}
host=${2:-}
port=${3:-2222}
[ -n "$machine" ] && [ -n "$host" ] || usage

flake=${CLAN_FLAKE:-/home/grmpf/synced/projects/hyperconfig}
dataset=${ZFS_DATASET:-zroot/root}

passphrase=$(clan vars get --flake "$flake" "$machine" zfs-key/passphrase)
if [ -z "$passphrase" ]; then
  echo "clan-unlock: no zfs-key/passphrase for $machine" >&2
  exit 1
fi

# The initrd sshd has its own host key, so it never matches the installed
# system's entry in known_hosts.
printf '%s' "$passphrase" | ssh \
  -p "$port" \
  -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${XDG_STATE_HOME:-$HOME/.local/state}/clan-unlock.known_hosts" \
  "root@$host" \
  "zfs load-key -L file:///dev/stdin $dataset && systemctl restart sysroot.mount && { systemctl default || true; }"
