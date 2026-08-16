# Pull the storage box's depth archive into the vault, newest hours first.
#
# rclone COPY, never sync: the box prunes depth after 60 days, and a sync
# would faithfully reproduce that deletion locally, destroying exactly the
# history this archive exists to keep. Copy only ever adds.
#
# Newest-first (--order-by modtime,descending) matters for the initial pass:
# it can run for days, and the recent hours are the ones anyone wants first.
# Later passes are cheap - rclone skips files already present by size+modtime.
#
# Everything is parameterised through the environment by the unit.
dest=$SB_DEST
passfile=$SB_PASSWORD_FILE
host=$SB_HOST
user=$SB_USER
port=$SB_PORT
remote=$SB_REMOTE_DIR
reserve_gib=$SB_RESERVE_GIB
transfers=$SB_TRANSFERS
checkers=$SB_CHECKERS

# The dataset must actually be mounted. RequiresMountsFor covers the ordinary
# case; this catches the pathological one, where writing into an unmounted
# mountpoint would silently fill the root filesystem instead.
if ! mountpoint -q "$(dirname "$dest")"; then
  echo "storagebox-sync: $(dirname "$dest") is not a mountpoint; refusing" >&2
  exit 1
fi
mkdir -p "$dest"

# Bound each run by the free space actually available, keeping a reserve.
# rclone has no global --min-free-space, so the budget becomes --max-transfer
# with cutoff-mode soft: in-flight files finish, no new ones start. Without
# this a long initial sync would happily fill the pool.
avail_kib=$(df -Pk "$dest" | awk 'NR == 2 { print $4 }')
budget_mib=$((avail_kib / 1024 - reserve_gib * 1024))
if [ "$budget_mib" -le 0 ]; then
  echo "storagebox-sync: only $((avail_kib / 1048576)) GiB free on $dest," \
    "below the ${reserve_gib} GiB reserve; nothing transferred" >&2
  exit 1
fi

# Host key: the pin NixOS deploys is the plain-hostname form, which Go's
# knownhosts only matches on port 22 - a non-default port is looked up as
# "[host]:port". Port 23 is also a different daemon (OpenSSH, offering
# ed25519 we have no pin for) than port 22 (mod_sftp, RSA only), so the RSA
# family is forced to select the key we actually pinned.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
pin=$(awk -v h="$host" \
  'index($1, h) > 0 && $2 == "ssh-rsa" { print $2 " " $3; exit }' \
  /etc/ssh/ssh_known_hosts 2>/dev/null || true)
if [ -z "$pin" ]; then
  echo "storagebox-sync: no ssh-rsa pin for $host in /etc/ssh/ssh_known_hosts" >&2
  exit 1
fi
printf '%s %s\n[%s]:%s %s\n' "$host" "$pin" "$host" "$port" "$pin" \
  >"$workdir/known_hosts"

RCLONE_SFTP_PASS=$(tr -d '\n' <"$passfile" | rclone obscure -)
export RCLONE_SFTP_PASS
export RCLONE_SFTP_HOST=$host RCLONE_SFTP_USER=$user RCLONE_SFTP_PORT=$port
export RCLONE_SFTP_KNOWN_HOSTS_FILE=$workdir/known_hosts
export RCLONE_SFTP_HOST_KEY_ALGORITHMS="rsa-sha2-512 rsa-sha2-256 ssh-rsa"
# SFTP-only account: skip the remote-shell probe (a wasted round trip at
# ~200 ms, once per invocation).
export RCLONE_SFTP_SHELL_TYPE=none

echo "storagebox-sync: :sftp:$remote -> $dest (budget ${budget_mib} MiB," \
  "${transfers} transfers, newest first)"

ec=0
rclone copy ":sftp:$remote" "$dest" \
  --order-by 'modtime,descending' \
  --transfers "$transfers" --checkers "$checkers" \
  --multi-thread-streams 1 \
  --max-transfer "${budget_mib}M" --cutoff-mode soft \
  --retries 3 --low-level-retries 10 \
  --timeout 120s --contimeout 30s \
  --stats 5m --stats-one-line \
  --log-level INFO || ec=$?

# 8 = --max-transfer reached. That is the free-space budget doing its job,
# not a failure: the next run continues where this one stopped.
if [ "$ec" -eq 8 ]; then
  echo "storagebox-sync: stopped on the ${reserve_gib} GiB free-space reserve" >&2
  exit 0
fi
exit "$ec"
