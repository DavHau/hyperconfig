# Detach the storage-box mount fast, so stopping the unit never stalls a
# nixos-rebuild switch.
#
# The hang this avoids: systemd SIGTERMs sshfs and waits, but sshfs cannot
# finish unmounting while FUSE requests are still in flight. On a ~200 ms
# link mid-read - or with any process holding an fd or cwd under the
# mountpoint - that wait runs to TimeoutStopSec (90 s by default) before
# systemd resorts to SIGKILL. A switch then looks frozen on
# "stopping the following units: storagebox-mount.service".
#
# Two steps, in this order:
#   1. lazy unmount, which detaches the tree immediately even when busy;
#   2. abort the FUSE connection, which fails every pending request with
#      ENOTCONN so sshfs's session loop returns and the process exits.
#
# The connection id must be read BEFORE the unmount: a lazy detach removes
# the row from mountinfo straight away, and then there is nothing left to
# look the id up from.
#
# Aborting cannot lose data here: the mount is read-only, so no dirty pages
# exist to flush. On a read-write mount this would need a sync first.
mountpoint=$1

dev=$(awk -v m="$mountpoint" '$5 == m { print $3; exit }' /proc/self/mountinfo)

fusermount3 -uz "$mountpoint" 2>/dev/null || true

if [ -n "$dev" ]; then
  abort=/sys/fs/fuse/connections/${dev#*:}/abort
  if [ -w "$abort" ]; then
    echo 1 >"$abort"
    echo "storagebox: aborted fuse connection ${dev#*:} for $mountpoint"
  fi
fi

exit 0
