# Answer systemd-cryptsetup's pending passphrase request with stdin.
# Run in the initrd over ssh by `clan-unlock <machine>`.
device=$LUKS_DEVICE
passphrase=$(cat)

for _ in $(seq 30); do
  for ask in /run/systemd/ask-password/ask.*; do
    [ -e "$ask" ] || continue
    grep -qxF "Id=cryptsetup:$device" "$ask" || continue
    socket=$(sed -n 's/^Socket=//p' "$ask")
    printf '%s' "$passphrase" | "$REPLY_PASSWORD" 1 "$socket"
    echo "passphrase sent for $device; boot continues if it was right"
    exit 0
  done
  sleep 1
done
echo "no pending passphrase request for $device" >&2
exit 1
