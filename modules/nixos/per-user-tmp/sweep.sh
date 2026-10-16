# Boot-time sweep of the shared /tmp and /var/tmp: files a polyinstantiated
# user left there (before per-user tmp, or from a process outside any PAM
# session) are invisible to that user now, so move each into the owner's
# own instance. systemd-private-* dirs of previous boots are dead and go.
#
# Only at boot, before user sessions start: moving files out from under a
# running session would break it. "$@" = the polyinstantiated users.

state=$(systemctl is-system-running || true)
if [ "$state" != starting ] && [ "$state" != initializing ]; then
  echo "per-user-tmp-sweep: system is $state, not booting; nothing done"
  exit 0
fi

declare -A polyinst=()
for u in "$@"; do polyinst[$u]=1; done
boot_id=$(tr -d - </proc/sys/kernel/random/boot_id)

for dir in /tmp /var/tmp; do
  [ -d "$dir/.inst" ] || continue
  dir_dev=$(stat -c %d "$dir")
  while IFS=$'\t' read -r -d '' owner name; do
    [ "$name" = .inst ] && continue
    [ -n "${polyinst[$owner]:-}" ] || continue
    entry=$dir/$name
    # Something mounted there is not a leftover.
    [ "$(stat -c %d "$entry")" = "$dir_dev" ] || continue
    case $name in
      systemd-private-"$boot_id"-*) continue ;;
      systemd-private-*)
        rm -rf --one-file-system -- "$entry"
        echo "removed stale $entry ($owner)"
        continue
        ;;
    esac
    dest=$dir/.inst/$owner/$name
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      echo "kept $entry: $dest already exists" >&2
      continue
    fi
    mv -- "$entry" "$dest"
    echo "moved $entry -> $dest"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%u\t%f\0')
done
