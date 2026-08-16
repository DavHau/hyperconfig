# Tune a FUSE mount for a high-latency link.
#
# Three limits stack here, and the smallest one wins. Measured on amy against
# the Hetzner box (~200 ms RTT), where plain SFTP sustains 6-7 MB/s:
#
#   1. request size   sshfs asks for at most 64 KB (sshfs.c:4489), set via
#                     -o max_read in the unit. Default 32 KB gave 1.16 MB/s;
#                     raising it to the ceiling gave ~2.5 MB/s.
#   2. readahead      the kernel's per-backing-device window, default 128 KB.
#   3. max_background FUSE's cap on concurrent *background* requests, which
#                     is the class readahead uses. Default 12, and 12 x 64 KB
#                     / 0.2 s ~ 3.8 MB/s - so this alone bounds the mount to
#                     roughly what we measured, no matter how large (2) is.
#
# Hence all three, or none of it helps: in-flight bytes = requests x size,
# and throughput = in-flight bytes / RTT.
#
# The mount does not exist yet when ExecStartPost fires (sshfs is still
# connecting), hence the wait loop rather than a one-shot write.
mountpoint=$1
kb=$2
background=$3

for _ in $(seq 1 60); do
  # /proc/self/mountinfo field 3 is the "major:minor"; it names both the bdi
  # and (via the minor) the fuse connection directory.
  dev=$(awk -v m="$mountpoint" '$5 == m { print $3; exit }' /proc/self/mountinfo)
  if [ -n "$dev" ] && [ -w "/sys/class/bdi/$dev/read_ahead_kb" ]; then
    echo "$kb" >"/sys/class/bdi/$dev/read_ahead_kb"

    conn=/sys/fs/fuse/connections/${dev#*:}
    if [ -w "$conn/max_background" ]; then
      echo "$background" >"$conn/max_background"
      # Kernel keeps this at ~75% of max_background; match that ratio so
      # congestion is not declared long before the queue is actually full.
      [ -w "$conn/congestion_threshold" ] &&
        echo $((background * 3 / 4)) >"$conn/congestion_threshold"
    fi

    echo "storagebox: $mountpoint read_ahead_kb=$kb max_background=$background (dev $dev)"
    exit 0
  fi
  sleep 1
done

echo "storagebox: $mountpoint never appeared in mountinfo; left untuned" >&2
exit 1
