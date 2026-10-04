# Answer systemd-cryptsetup's passphrase request with the key from Tang.
# args: <mapper name> <LUKS source device> <clevis JWE of the key>
#
# A password agent (systemd.io/PASSWORD_AGENTS) next to the console one:
# the prompt stays usable the whole time, and whichever answers first wins.
# Tang is retried until the volume is open, so a server that comes up later
# (unlocked by hand after a power cut) still unlocks this machine.
name=$1
device=$2
jwe=$3
dir=/run/systemd/ask-password
answered=

while [ ! -e "/dev/mapper/$name" ]; do
  for ask in "$dir"/ask.*; do
    [ -e "$ask" ] || continue
    # systemd-cryptsetup's Id is "cryptsetup:" + the crypttab source.
    grep -qxF "Id=cryptsetup:$device" "$ask" || continue
    socket=$(sed -n 's/^Socket=//p' "$ask")
    [ -n "$socket" ] || continue
    # Every answer costs one of systemd-cryptsetup's tries. A key from Tang
    # that LUKS rejects (keyslot gone) will not improve, so offer it once
    # and leave the remaining tries to the console.
    [ -z "$answered" ] || exit 0
    if key=$(clevis decrypt <"$jwe" 2>/dev/null); then
      printf '%s' "$key" | "$REPLY_PASSWORD" 1 "$socket" &&
        answered=1 && echo "answered $name's passphrase request via Tang"
    fi
  done
  sleep 2
done
