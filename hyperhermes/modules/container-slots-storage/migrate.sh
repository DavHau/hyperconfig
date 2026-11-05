# slot-storage-migrate <slot> [--dry-run]
# slot-storage-migrate --finalize <slot>
#
# Moves a container slot's existing root tree onto its datasets (see
# container-slots-storage/default.nix): stops the slot, copies the root
# into the root dataset (at a temporary mountpoint), moves the contents of
# the scratch paths into the scratch dataset, renames the old root to
# /var/lib/nixos-containers/.premigrate-<slot>, mounts the dataset in its
# place and starts the slot again if it was running. The old tree stays
# until --finalize. Refuses when the root without the scratch paths does
# not fit rootQuota, or the pool has no room for the copy.

conf=/etc/container-slots/storage.json

die() {
  echo "slot-storage-migrate: $*" >&2
  exit 1
}
say() { echo "slot-storage-migrate: $*"; }

usage() { die "usage: slot-storage-migrate <slot> [--dry-run] | --finalize <slot>"; }

finalize=0
dry=0
slot=""
for a in "$@"; do
  case "$a" in
    --finalize) finalize=1 ;;
    --dry-run) dry=1 ;;
    -*) usage ;;
    *)
      [ -z "$slot" ] || usage
      slot=$a
      ;;
  esac
done
[ -n "$slot" ] || usage
[ "$(id -u)" = 0 ] || die "run as root"
[ -r "$conf" ] || die "$conf missing: services.container-slots.storage is off"

get() { jq -r --arg s "$slot" ".slots[\$s]$1" "$conf"; }
[ "$(get '| type')" = object ] ||
  die "slot $slot does not use storage (services.container-slots.slots.$slot.storage.enable)"

root=$(get .root)
rootDs=$(get .rootDataset)
rootQuota=$(get .rootQuota)
scratch=$(get .scratch)
scratchDs=$(get .scratchDataset)
scratchQuota=$(get .scratchQuota)
old=$(dirname "$root")/.premigrate-$slot
tmp=/var/lib/slot-storage-migrate/$slot

exists() { zfs list -H -o name "$1" >/dev/null 2>&1; }
mounted_on() { findmnt -rn -o SOURCE --mountpoint "$1" 2>/dev/null | tail -n 1 || true; }
bytes() { numfmt --from=iec "$1"; }
human() { numfmt --to=iec "$1"; }
size() { du -sx -B1 "$1" | cut -f1; }

if [ "$finalize" = 1 ]; then
  [ "$(mounted_on "$root")" = "$rootDs" ] || die "$root is not $rootDs yet; nothing to finalize"
  [ -d "$old" ] || die "no old tree at $old"
  say "deleting the old tree $old"
  rm -rf --one-file-system "$old"
  exit 0
fi

if [ "$(mounted_on "$root")" = "$rootDs" ]; then
  say "$slot already lives on $rootDs"
  exit 0
fi
[ ! -L "$root" ] || die "$root is a symlink"
[ -d "$root" ] && [ -n "$(ls -A "$root")" ] ||
  die "$root is empty or absent: nothing to migrate, the next start of the slot creates its datasets"
[ ! -e "$old" ] || die "$old exists (an earlier migration?); remove it first"
if exists "$rootDs"; then
  [ "$(zfs get -H -o value mountpoint "$rootDs")" = "$tmp" ] ||
    die "$rootDs exists and is not mounted at $tmp (a stray dataset?); refusing"
fi
# The scratch binds are idmapped: they expect guest ids on disk, as an
# idmapped root has them (nspawn's ownership "map", ZFS's case). A root
# chowned into the slot's host range would need its ids shifted back.
[ "$(stat -c %u "$root")" -lt 65536 ] ||
  die "$root is owned by host uid $(stat -c %u "$root"): a chown-shifted root, not an idmapped one; not supported"

# The scratch paths whose contents move: real directories in the old
# root, checked component by component from the top (the slot is stopped
# before anything moves, but its tree is its own: a symlink anywhere on the
# way could point the move at this host's files). Others stay in the root.
mapfile -t paths < <(get '.paths[] | [.path, .dir, .owner, .group, .mode] | @tsv')
moving=()
for line in "${paths[@]}"; do
  IFS=$'\t' read -r path _ <<<"$line"
  p=$root
  safe=1
  IFS=/ read -ra parts <<<"${path#/}"
  for c in "${parts[@]}"; do
    p=$p/$c
    if [ -L "$p" ]; then
      say "warning: $p is a symlink; /${path#/} stays in the root"
      safe=0
      break
    fi
    [ -e "$p" ] || {
      safe=0
      break
    }
  done
  if [ "$safe" = 1 ] && [ -d "$root$path" ]; then
    moving+=("$line")
  fi
done

say "measuring $root (du, may take a while)"
total=$(size "$root")
moved=0
for line in "${moving[@]}"; do
  IFS=$'\t' read -r path _ <<<"$line"
  s=$(size "$root$path")
  say "  $path: $(human "$s") -> scratch"
  moved=$((moved + s))
done
kept=$((total - moved))
say "root: $(human "$total") in all, $(human "$kept") stays backed up, $(human "$moved") moves to scratch"

fail=0
if [ "$rootQuota" != null ]; then
  if [ "$kept" -gt "$(bytes "$rootQuota")" ]; then
    say "does not fit rootQuota $rootQuota; largest directories (MiB) staying in the root:"
    excludes=()
    for line in "${moving[@]}"; do
      IFS=$'\t' read -r path _ <<<"$line"
      excludes+=("--exclude=$root$path")
    done
    du -x -B1M -d 3 "${excludes[@]}" "$root" | sort -n | tail -n 25
    say "move some to scratch (storage.scratchPaths) or raise storage.rootQuota"
    fail=1
  elif [ "$kept" -gt $(($(bytes "$rootQuota") * 8 / 10)) ]; then
    say "warning: above 80% of rootQuota $rootQuota from the start"
  fi
fi
if [ "$scratchQuota" != null ] && [ "$moved" -gt "$(bytes "$scratchQuota")" ]; then
  say "the scratch paths ($(human "$moved")) do not fit scratchQuota $scratchQuota"
  fail=1
fi
# The copy of the root needs room until --finalize; moving the scratch
# paths frees as much as it takes (minus what snapshots keep).
pool=${rootDs%%/*}
avail=$(zfs get -Hp -o value available "$pool")
if [ "$kept" -gt $((avail * 9 / 10)) ]; then
  say "pool $pool has $(human "$avail") available, too little for a $(human "$kept") copy"
  fail=1
fi
[ "$fail" = 0 ] || exit 1

if [ "$dry" = 1 ]; then
  say "dry run: would stop container@$slot, copy $root to $rootDs, move the paths above to $scratchDs, keep the old tree at $old"
  exit 0
fi

mapfile -t units < <(get '.units[]')
was=$(systemctl is-active "container@$slot.service" || true)

# Nothing may start the slot while its root is copied: an agent's
# `slot start`, a share unit or an operator would run it on the old root,
# and whatever it wrote after the copy would be lost at the swap. A
# runtime drop-in makes every start a no-op until this tool lifts it
# right before its own start; on failure it stays, the slot stopped.
lock=/run/systemd/system/container@$slot.service.d/50-storage-migrate.conf
install -d -m 0755 "$(dirname "$lock")"
printf '[Unit]\n# slot-storage-migrate %s is running; remove this file to allow starts.\nConditionPathExists=/run/slot-storage-migrate-done-%s\n' "$slot" "$slot" >"$lock"
systemctl daemon-reload
say "stopping ${units[*]} (starts blocked by $lock)"
systemctl stop "${units[@]}"

trap 'say "failed; state: old root $root (or $old), $rootDs at $(zfs get -H -o value mountpoint "$rootDs" 2>/dev/null || echo -), scratch contents moved so far in $scratch. The slot is stopped and cannot start until $lock is removed (then systemctl daemon-reload)."' ERR

for parent in "$(jq -r .rootParent "$conf")" "$(jq -r .scratchParent "$conf")"; do
  exists "$parent" || zfs create -o canmount=off -o mountpoint=none "$parent"
done

# scratch dataset, at its final place
quotaOpt() { [ "$2" = null ] || echo "-o $1=$2"; }
if [ "$(mounted_on "$scratch")" != "$scratchDs" ]; then
  if [ -e "$scratch" ] && [ -n "$(ls -A "$scratch")" ]; then
    die "$scratch holds data and is not $scratchDs"
  fi
  install -d -m 0700 "$(dirname "$scratch")"
  if exists "$scratchDs"; then
    [ "$(zfs get -H -o value mountpoint "$scratchDs")" = "$scratch" ] || die "$scratchDs is not set to mount at $scratch"
    zfs mount "$scratchDs"
  else
    # shellcheck disable=SC2046
    zfs create -o mountpoint="$scratch" $(quotaOpt quota "$scratchQuota") "$scratchDs"
  fi
fi
chown 0:0 "$scratch"
chmod 0700 "$scratch"

# root dataset, at a temporary place
if ! exists "$rootDs"; then
  install -d -m 0700 "$(dirname "$tmp")"
  # shellcheck disable=SC2046
  zfs create -o mountpoint="$tmp" $(quotaOpt refquota "$rootQuota") "$rootDs"
fi
[ "$(mounted_on "$tmp")" = "$rootDs" ] || zfs mount "$rootDs"

excludes=()
for line in "${moving[@]}"; do
  IFS=$'\t' read -r path _ <<<"$line"
  excludes+=("--exclude=$path/*")
done
say "copying $root to $rootDs"
rsync -aHAXS --numeric-ids --one-file-system --delete "${excludes[@]}" "$root/" "$tmp/"

for line in "${moving[@]}"; do
  IFS=$'\t' read -r path dir owner group mode <<<"$line"
  dst=$scratch/$dir
  [ -d "$dst" ] || install -d -m "$mode" -o "$owner" -g "$group" "$dst"
  say "moving $path to $dst"
  rsync -aHAXS --numeric-ids --one-file-system --remove-source-files "$root$path/" "$dst/"
  find "$root$path" -mindepth 1 -depth -type d -empty -delete
done

say "keeping the old root as $old"
mv "$root" "$old"
zfs set mountpoint="$root" "$rootDs"
rmdir "$tmp" 2>/dev/null || true
trap - ERR

[ "$(mounted_on "$root")" = "$rootDs" ] || die "$root is not $rootDs after the switch"
rm -f "$lock"
rmdir "$(dirname "$lock")" 2>/dev/null || true
systemctl daemon-reload
if [ "$was" = active ]; then
  say "starting container@$slot"
  systemctl reset-failed "container@$slot.service" 2>/dev/null || true
  systemctl start "container@$slot.service"
  leader=$(machinectl show "$slot" -p Leader --value)
  missing=0
  while IFS= read -r path; do
    if ! findmnt -rn --task "$leader" --mountpoint "$path" >/dev/null; then
      say "warning: $path is not bound in the running slot"
      missing=1
    fi
  done < <(get '.paths[].path')
  [ "$missing" = 0 ] && say "the slot runs with its scratch binds"
else
  say "container@$slot was $was before; not starting it"
fi
zfs list -o name,used,refer,quota,refquota,mountpoint "$rootDs" "$scratchDs"
say "check the slot, then: slot-storage-migrate --finalize $slot"
