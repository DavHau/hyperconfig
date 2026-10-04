# Unlock an encrypted ZFS root in the initrd.
# args: <dataset> [clevis JWE of the passphrase]
#
# With a JWE, the Tang servers get a head start before the console prompt
# appears; after that every prompt timeout tries them once more, so a server
# coming up later (e.g. unlocked by hand after a power cut) still unlocks
# this machine. The prompt re-arms on timeout instead of blocking forever, so
# a key loaded out of band (clan-unlock over ssh) also ends the loop within
# one timeout and the boot continues.
dataset=$1
jwe=${2:-}
timeout=15
head_start=30

keystatus() {
  zfs get -H -o value keystatus "$dataset" 2>/dev/null || echo unavailable
}

tang_unlock() {
  [ -n "$jwe" ] || return 1
  local passphrase
  # clevis reports every unreachable server; the console is the prompt's.
  passphrase=$(clevis decrypt <"$jwe" 2>/dev/null) || return 1
  printf '%s' "$passphrase" | zfs load-key -L file:///dev/stdin "$dataset" || return 1
  echo "unlocked $dataset via Tang"
}

if [ -n "$jwe" ]; then
  # Link-local needs no DHCP, but the NIC may still be coming up.
  while [ "$SECONDS" -lt "$head_start" ] && [ "$(keystatus)" != "available" ]; do
    tang_unlock || sleep 2
  done
fi

while [ "$(keystatus)" != "available" ]; do
  if passphrase=$(systemd-ask-password --timeout="$timeout" "Enter passphrase for $dataset:"); then
    printf '%s' "$passphrase" | zfs load-key -L file:///dev/stdin "$dataset" ||
      echo "wrong passphrase for $dataset" >&2
  else
    tang_unlock || true
  fi
done
