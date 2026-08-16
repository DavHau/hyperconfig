#!/usr/bin/env bash
# Does parallelism fix the Thailand -> Falkenstein throughput?
#
# The path is ~200 ms RTT. A single TCP stream there collapses to a few MB/s
# on a hair of packet loss, and for a DOWNLOAD the congestion control is
# sender-side (Hetzner's box), so no client-side tuning touches it. The only
# client lever is more streams: N connections = N congestion windows.
#
# This measures a fixed byte budget three ways and prints MB/s:
#   1 baseline  - one file, one stream           (what you have today)
#   2 multi     - one file, N streams            (what -o max_conns=N buys)
#   3 parallel  - N files, N transfers           (unambiguous control: N TCP conns)
#
# If 2 and 3 do not beat 1, parallelism is pointless on this route and the
# answer is a better-peered path (Singapore relay) or an ISP tier instead.
#
# Usage:
#   ./storagebox-speedtest.sh [-b BUDGET_MB] [-s STREAMS] [-p PORT]
#                             [-d REMOTE_DIR] [-f REMOTE_FILE] [-m MACHINE]
#                             [-r REPEATS]
set -euo pipefail

HOST=u632961-sub1.your-storagebox.de
USER_NAME=u632961-sub1
PORT=23 # Hetzner documents 23 as faster than 22
BUDGET_MB=128
STREAMS=8
REMOTE_DIR=depth
REMOTE_FILE=
MOUNTPOINT=/mnt/storagebox
MACHINE=amy
REPEATS=1

while getopts ':b:s:p:d:f:m:r:h' opt; do
  case "$opt" in
  b) BUDGET_MB=$OPTARG ;;
  s) STREAMS=$OPTARG ;;
  p) PORT=$OPTARG ;;
  d) REMOTE_DIR=$OPTARG ;;
  f) REMOTE_FILE=$OPTARG ;;
  m) MACHINE=$OPTARG ;;
  r) REPEATS=$OPTARG ;;
  h)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *)
    echo "unknown option: -$OPTARG" >&2
    exit 2
    ;;
  esac
done

command -v rclone >/dev/null || {
  echo "rclone missing; run: nix shell nixpkgs#rclone" >&2
  exit 1
}

# Password: from the clan var by default, or RCLONE_SFTP_PASS_PLAIN as an
# override. printf %s matters - a trailing newline would be obscured into the
# password and auth would fail.
if [ -n "${RCLONE_SFTP_PASS_PLAIN:-}" ]; then
  pw=$RCLONE_SFTP_PASS_PLAIN
else
  command -v clan >/dev/null || {
    echo "clan missing and RCLONE_SFTP_PASS_PLAIN unset" >&2
    exit 1
  }
  pw=$(clan vars get "$MACHINE" storagebox/password)
fi

RCLONE_SFTP_PASS=$(printf %s "$pw" | rclone obscure -)
unset pw
export RCLONE_SFTP_HOST=$HOST RCLONE_SFTP_USER=$USER_NAME RCLONE_SFTP_PORT=$PORT
export RCLONE_SFTP_PASS
# The account is SFTP-only; without this rclone probes for a remote shell on
# every invocation (a wasted round trip at 200 ms, plus a NOTICE each run).
export RCLONE_SFTP_SHELL_TYPE=none
export RCLONE_SFTP_SET_MODTIME=false

dest=$(mktemp -d /tmp/sbspeed.XXXXXX)
# Downloads land in a SUBDIR: run_test wipes it between tests, and the
# generated known_hosts / listing must survive that wipe.
dldir=$dest/dl
mkdir -p "$dldir"
cleanup() { rm -rf "$dest"; }
trap cleanup EXIT

# Validate the host key against the same pin the NixOS module deploys
# (programs.ssh.knownHosts lands in /etc/ssh/ssh_known_hosts). We send the
# account password over this connection, so unvalidated is the fallback, not
# the default.
#
# Two traps on port 23, both verified against the live box:
#  - Ports 22 and 23 are DIFFERENT servers: 22 is mod_sftp (RSA only), 23 is
#    OpenSSH 9.6 (RSA + ecdsa + ed25519). Same RSA host key on both.
#  - Go's knownhosts looks a non-default port up as "[host]:port", so the
#    plain-hostname pin NixOS writes only ever matches port 22 ("key is
#    unknown"). Hence both forms below.
# Forcing the RSA family then stops Go preferring the ed25519 key we have no
# pin for ("key mismatch"). rsa-sha2-* are the same RSA key with a modern
# signature - plain ssh-rsa (SHA-1) is disabled by default in OpenSSH >= 8.8.
system_known_hosts=/etc/ssh/ssh_known_hosts
pin=$(awk -v h="$HOST" \
  'index($1, h) > 0 && $2 == "ssh-rsa" { print $2 " " $3; exit }' \
  "$system_known_hosts" 2>/dev/null || true)
if [ -n "$pin" ]; then
  printf '%s %s\n[%s]:%s %s\n' "$HOST" "$pin" "$HOST" "$PORT" "$pin" \
    >"$dest/known_hosts"
  export RCLONE_SFTP_KNOWN_HOSTS_FILE=$dest/known_hosts
  export RCLONE_SFTP_HOST_KEY_ALGORITHMS="rsa-sha2-512 rsa-sha2-256 ssh-rsa"
else
  export RCLONE_SFTP_KNOWN_HOSTS_FILE=none
  echo "warning: no ssh-rsa pin for $HOST in $system_known_hosts" >&2
  echo "         host key NOT validated - the password goes over this link" >&2
fi

bigsize=0
if [ -n "$REMOTE_FILE" ]; then
  bigfile=$REMOTE_FILE
else
  echo "probing :sftp:$REMOTE_DIR on $HOST:$PORT ..."
  listing=$dest/listing.txt
  # Deliberately NOT `sort | head`: head exits early, sort dies of SIGPIPE,
  # and pipefail + set -e then kill this script with no message at all.
  # One awk pass picks the largest file and cannot SIGPIPE anything.
  if ! rclone lsl ":sftp:$REMOTE_DIR" --max-depth 1 >"$listing"; then
    echo "listing :sftp:$REMOTE_DIR failed" >&2
    exit 1
  fi
  # lsl prints "<size> <date> <time> <path>"; a path may contain spaces, so
  # rebuild it from field 4 onward.
  read -r bigsize bigfile <<<"$(awk '{
      size = $1 + 0
      path = $4
      for (i = 5; i <= NF; i++) path = path " " $i
      if (size > max) { max = size; best = path }
    } END { print max, best }' "$listing")"
  [ -n "$bigfile" ] || {
    echo "no files found under :sftp:$REMOTE_DIR" >&2
    exit 1
  }
fi

echo "test file: $bigfile"
echo "budget:    ${BUDGET_MB} MiB per test, ${STREAMS} streams, ${REPEATS} repeat(s)"
echo

# rclone exits 8 when --max-transfer trips; that is the expected stop here.
run_test() {
  local label=$1
  shift
  local start end elapsed ec=0
  rm -rf "${dldir:?}"/*
  start=$(date +%s.%N)
  rclone "$@" --retries 1 --timeout 60s --contimeout 20s \
    --stats 10s --stats-one-line \
    --max-transfer "${BUDGET_MB}M" --cutoff-mode hard || ec=$?
  end=$(date +%s.%N)
  if [ "$ec" -ne 0 ] && [ "$ec" -ne 8 ]; then
    echo "  $label: rclone failed (exit $ec)" >&2
    return 1
  fi
  elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { print b - a }')
  awk -v mb="$BUDGET_MB" -v s="$elapsed" -v l="$label" \
    'BEGIN { printf "  %-22s %7.2f MB/s  (%.0fs)\n", l, mb / s, s }'
}

# Test 4: the same bytes through the sshfs mount. rclone measures the LINK;
# this measures what your shell actually gets from /mnt/storagebox. A large
# gap means sshfs's in-flight readahead is the bottleneck, not the network -
# a different fix entirely (max_readahead, not more connections).
#
# Reads from a random 1 MiB-aligned offset so a rerun does not just replay
# the kernel page cache, and to /dev/null so local disk write speed cannot
# confound the number.
mount_test() {
  local label="4 sshfs mount (read)"
  local path=$MOUNTPOINT/$REMOTE_DIR/$bigfile
  local skip=0 span start end elapsed bytes
  if [ ! -r "$path" ]; then
    printf '  %-22s skipped (%s not readable)\n' "$label" "$path"
    return 0
  fi
  span=$((bigsize / 1048576 - BUDGET_MB))
  [ "$span" -gt 0 ] && skip=$((RANDOM % span))
  start=$(date +%s.%N)
  bytes=$(dd if="$path" of=/dev/null bs=1M count="$BUDGET_MB" skip="$skip" 2>&1 |
    awk '/bytes/ { print $1; exit }')
  end=$(date +%s.%N)
  [ -n "$bytes" ] || {
    printf '  %-22s read failed\n' "$label"
    return 1
  }
  elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { print b - a }')
  awk -v by="$bytes" -v s="$elapsed" -v l="$label" \
    'BEGIN { printf "  %-22s %7.2f MB/s  (%.0fs)\n", l, by / 1048576 / s, s }'
}

for i in $(seq 1 "$REPEATS"); do
  [ "$REPEATS" -gt 1 ] && echo "round $i:"
  # Back-to-back so time-of-day congestion hits all three roughly equally.
  run_test "1 baseline (1 stream)" copy ":sftp:$REMOTE_DIR/$bigfile" "$dldir" \
    --transfers 1 --multi-thread-streams 1
  run_test "2 multi ($STREAMS streams)" copy ":sftp:$REMOTE_DIR/$bigfile" "$dldir" \
    --transfers 1 --multi-thread-streams "$STREAMS" --multi-thread-cutoff 16M
  run_test "3 parallel ($STREAMS files)" copy ":sftp:$REMOTE_DIR" "$dldir" \
    --transfers "$STREAMS" --multi-thread-streams 1 --max-depth 1
  mount_test
  echo
done

cat <<EOF
Reading it:
  2 or 3 >> 1    -> per-stream limited; parallel connections would help
  2 and 3 ~= 1   -> single stream already saturates the path; more
                    connections buy nothing (measured 2026-08-16: 6.56 /
                    6.54 / ~3.5 MB/s - parallelism ruled out on this route)
  4 << 1         -> the LINK is fine and sshfs is the bottleneck; fix is
                    -o max_readahead on the mount, not more connections
  4 ~= 1         -> mount is as good as the link; remaining lever is a
                    better-peered path (Singapore relay) or an ISP tier
Run it twice at different hours before deciding - Thai transit varies a lot.
EOF
