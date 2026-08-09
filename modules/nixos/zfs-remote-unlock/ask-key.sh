# Console passphrase prompt for an encrypted ZFS root, in the initrd.
# args: <dataset> [prompt timeout in seconds]
#
# The prompt re-arms on timeout instead of blocking forever, so a key loaded
# out of band (clan-unlock over ssh) ends this loop within one timeout and the
# boot continues.
dataset=$1
timeout=${2:-15}

keystatus() {
  zfs get -H -o value keystatus "$dataset" 2>/dev/null || echo unavailable
}

while [ "$(keystatus)" != "available" ]; do
  if passphrase=$(systemd-ask-password --timeout="$timeout" "Enter passphrase for $dataset:"); then
    printf '%s' "$passphrase" | zfs load-key -L file:///dev/stdin "$dataset" ||
      echo "wrong passphrase for $dataset" >&2
  fi
done
