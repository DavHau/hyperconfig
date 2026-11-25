# container-slot-storage prepare <slot> | quotas
#
# prepare: before container@<slot> starts, as host root, slot stopped.
# Creates or mounts the slot's root and scratch datasets over absent or
# empty directories only, creates the scratch subdirectories, and writes
# the nspawn binds for them to /run/container-slots/<slot>/storage.env, or
# removes that file while the root is not (yet) the dataset. A directory
# that holds data, or a dataset mounted elsewhere, does not stop the start:
# the slot runs on its directory, without the binds, and the log says why.
# (ensure_dataset runs in `||` context, where set -e is off: each step
# checks its own status.) Data paths are the exception: they fail the
# unit, and so the start, whenever binding them could hide data or bind a
# half-copied dataset (see data_path).
#
# quotas: applies the configured quotas and reservations to the datasets
# that exist.

conf=/etc/container-slots/storage.json

log() { echo "container-slot-storage: $*" >&2; }

# value of .slots[<slot>]<filter>
get() { jq -r --arg s "$slot" ".slots[\$s]$1" "$conf"; }

exists() { zfs list -H -o name "$1" >/dev/null 2>&1; }

# The dataset mounted on top of <dir>, if any.
mounted_on() { findmnt -rn -o SOURCE --mountpoint "$1" 2>/dev/null | tail -n 1; }

absent_or_empty() {
  [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
  [ -d "$1" ] && [ ! -L "$1" ] && [ -z "$(ls -A "$1")" ]
}

ensure_parent() {
  exists "$1" || zfs create -o canmount=off -o mountpoint=none "$1"
}

set_quota() { # dataset property value|null
  local v=$3
  [ "$v" = null ] && v=none
  if [ "$(zfs get -H -o value "$2" "$1")" != "$v" ]; then
    zfs set "$2=$v" "$1"
  fi
}

# ensure_dataset <dataset> <mountpoint> <quota property> <quota>: succeeds
# when <dataset> ends up mounted on <mountpoint>.
ensure_dataset() {
  local ds=$1 mnt=$2 prop=$3 quota=$4
  if [ "$(mounted_on "$mnt")" = "$ds" ]; then
    set_quota "$ds" "$prop" "$quota" || true
    return 0
  fi
  if exists "$ds"; then
    local mp
    mp=$(zfs get -H -o value mountpoint "$ds")
    if [ "$mp" != "$mnt" ]; then
      log "$slot: $ds is mounted at $mp, not $mnt (an unfinished slot-storage-migrate?); leaving it"
      return 1
    fi
    if ! absent_or_empty "$mnt"; then
      log "$slot: not mounting $ds: $mnt holds data"
      return 1
    fi
    zfs mount "$ds" || return 1
    set_quota "$ds" "$prop" "$quota" || true
    return 0
  fi
  if ! absent_or_empty "$mnt"; then
    log "$slot: $mnt holds data and is no dataset yet; migrate it with: slot-storage-migrate $slot"
    return 1
  fi
  if [ "$quota" = null ]; then
    zfs create -o mountpoint="$mnt" "$ds" || return 1
  else
    zfs create -o mountpoint="$mnt" -o "$prop=$quota" "$ds" || return 1
  fi
}

fail() {
  log "$slot: $*; not starting"
  exit 1
}

# guest_dir <root> <path>: fails if any component of <path> below <root>
# is a symlink (the tree is the slot's: a link could point this host's
# root at its own files) or the path exists and is no directory.
guest_dir() {
  local p=$1 c
  local -a parts
  IFS=/ read -ra parts <<<"${2#/}"
  for c in "${parts[@]}"; do
    p=$p/$c
    [ ! -L "$p" ] || return 1
    [ -e "$p" ] || return 0
  done
  [ -d "$p" ]
}

# copy_dir_attrs <from> <to>: owner, mode (setgid included) and ACL,
# default ACL included, of one directory.
copy_dir_attrs() {
  chown --reference="$1" "$2" &&
    chmod "$(stat -c %a "$1")" "$2" &&
    getfacl -n -c -- "$1" | setfacl --set-file=- -- "$2"
}

# data_path <root> <path> <dataset> <mnt> <quota> <reservation> <owner>
#   <group> <mode>: the path's dataset mounted on <mnt>, holding the
# guest's data; data already in the root is migrated in first. Exits the
# unit on any doubt.
data_path() {
  local root=$1 path=$2 ds=$3 mnt=$4 quota=$5 resv=$6 owner=$7 group=$8 mode=$9
  local g=$root$path created=0
  guest_dir "$root" "$path" || fail "$path in the slot has a symlink on its way or is no directory"
  if exists "$ds"; then
    [ "$(zfs get -H -o value mountpoint "$ds")" = "$mnt" ] || fail "$ds does not mount at $mnt"
    if [ "$(mounted_on "$mnt")" != "$ds" ]; then
      absent_or_empty "$mnt" || fail "$mnt holds data and is not $ds"
      zfs mount "$ds" || fail "cannot mount $ds"
    fi
  else
    absent_or_empty "$mnt" || fail "$mnt holds data and is no dataset"
    local -a opts=(-o mountpoint="$mnt" -o refquota="$quota")
    [ "$resv" = null ] || opts+=(-o refreservation="$resv")
    zfs create "${opts[@]}" "$ds" || fail "cannot create $ds"
    created=1
  fi
  set_quota "$ds" refquota "$quota" || fail "cannot set refquota on $ds"
  set_quota "$ds" refreservation "$resv" || fail "cannot set refreservation on $ds"

  local dsEmpty=0 guestData=0
  [ -n "$(ls -A "$mnt")" ] || dsEmpty=1
  if [ -d "$g" ] && [ -n "$(ls -A "$g")" ]; then guestData=1; fi
  if [ "$guestData" = 1 ] && [ "$dsEmpty" = 0 ]; then
    fail "both $g and $ds hold data. After an interrupted migration the root's copy is the original (snapshot $ds, then empty $mnt to migrate again); otherwise compare both first and move aside the one to drop"
  elif [ "$guestData" = 1 ]; then
    migrate_path "$g" "$ds" "$mnt" "$quota"
  elif [ "$dsEmpty" = 1 ] && [ "$created" = 1 ]; then
    if ! { chown "$owner:$group" "$mnt" && chmod "$mode" "$mnt"; }; then
      fail "cannot set up $mnt"
    fi
  fi
  if [ ! -d "$g" ]; then
    if ! { mkdir -p "$(dirname "$g")" && install -d -m "$mode" -o "$owner" -g "$group" "$g"; }; then
      fail "cannot create the mountpoint $g"
    fi
  fi
}

# migrate_path <guest dir> <dataset> <mnt>: copy, verify, swap. Until the
# rename the root is only read; a failure before it empties the dataset
# again and fails the unit.
migrate_path() {
  local g=$1 ds=$2 mnt=$3 quota=$4 aside used q
  aside=$g.premigrate-$(date -u +%Y%m%dT%H%M%SZ)
  # on disk in the root (same compression as the dataset), so a copy that
  # cannot fit fails here with a clear message instead of mid-way
  used=$(du -sx -B1 -- "$g" | cut -f1) || fail "cannot size $g"
  q=$(zfs get -Hp -o value refquota "$ds") || fail "cannot read the refquota of $ds"
  [ "$q" = 0 ] || [ "$used" -lt "$q" ] ||
    fail "$g uses $(numfmt --to=iec "$used"), not below the quota $quota of $ds; raise it"
  undo() {
    find "$mnt" -mindepth 1 -maxdepth 1 -exec rm -rf --one-file-system {} + || true
    fail "$*; $g is unchanged, $ds emptied again"
  }
  [ ! -e "$aside" ] || fail "$aside exists"
  log "$slot: migrating $g into $ds"
  rsync -aHAXS --numeric-ids --one-file-system "$g/" "$mnt/" || undo "copying $g failed"
  local diff
  diff=$(rsync -aHAXS --numeric-ids --one-file-system --delete --checksum --dry-run --itemize-changes "$g/" "$mnt/") ||
    undo "verifying $g failed"
  [ -z "$diff" ] || undo "$ds differs from $g after the copy: $(head -n 5 <<<"$diff")"
  log "$slot: $g verified ($(find "$mnt" | wc -l) entries, $(du -sh --apparent-size "$mnt" | cut -f1)); keeping it as $aside (delete it by hand once the slot is checked)"
  mv -T "$g" "$aside" || undo "cannot move $g aside"
  if ! { mkdir "$g" && copy_dir_attrs "$aside" "$g"; }; then
    fail "cannot recreate the empty mountpoint $g (the data is in $ds and in $aside)"
  fi
}

prepare() {
  local run=/run/container-slots/$slot
  install -d -m 0711 /run/container-slots "$run"
  rm -f "$run/storage.env"
  if [ "$(get '| type')" != object ]; then
    return 0
  fi

  local root scratch
  root=$(get .root)
  scratch=$(get .scratch)
  if [ -L "$root" ]; then
    # container-slots' prep refuses it with its own message
    return 0
  fi
  ensure_parent "$(jq -r .rootParent "$conf")"
  ensure_parent "$(jq -r .scratchParent "$conf")"
  local ok=1 rootOk=1
  ensure_dataset "$(get .rootDataset)" "$root" refquota "$(get .rootQuota)" || rootOk=0
  install -d -m 0700 "$(dirname "$scratch")"
  ensure_dataset "$(get .scratchDataset)" "$scratch" quota "$(get .scratchQuota)" || ok=0
  [ "$rootOk" = 1 ] || ok=0

  # Data paths: on a root dataset only (a root still a directory keeps
  # its data until slot-storage-migrate). Never start without the bind of
  # a dataset that holds data: the guest would write beside it.
  local flags="" path ds mnt quota resv owner group mode
  # A data dataset no path is configured for (one removed or renamed in
  # the config) keeps its data: refuse rather than start without it.
  local child base
  base=$(get .dataBase)
  if exists "$base"; then
    while IFS= read -r child; do
      [ "$child" != "$base" ] || continue
      if ! jq -e --arg s "$slot" --arg c "$child" '.slots[$s].data | any(.dataset == $c)' "$conf" >/dev/null; then
        fail "$child is no configured data path (removed or renamed?); restore its entry, or rename or destroy the dataset by hand"
      fi
    done < <(zfs list -H -t filesystem,volume -o name -r -d 1 "$base")
  fi
  if [ "$rootOk" = 0 ]; then
    while IFS=$'\t' read -r path ds; do
      if exists "$ds"; then
        fail "$ds exists for $path but the root is not its dataset; put the root back on its dataset (slot-storage-migrate) or destroy $ds if it is empty"
      fi
    done < <(get '.data[] | [.path, .dataset] | @tsv')
  elif [ "$(get '.data | length')" != 0 ]; then
    local dataDir
    dataDir=$(get .dataDir)
    ensure_parent "$(jq -r .dataParent "$conf")" || fail "cannot create $(jq -r .dataParent "$conf")"
    ensure_parent "$(get .dataBase)" || fail "cannot create $(get .dataBase)"
    install -d -m 0700 "$(dirname "$dataDir")" "$dataDir"
    chown 0:0 "$(dirname "$dataDir")" "$dataDir"
    chmod 0700 "$(dirname "$dataDir")" "$dataDir"
    while IFS=$'\t' read -r path ds mnt quota resv owner group mode; do
      data_path "$root" "$path" "$ds" "$mnt" "$quota" "$resv" "$owner" "$group" "$mode"
      flags="$flags --bind=$mnt:$path:idmap"
    done < <(get '.data[] | [.path, .dataset, .mnt, .quota, (.reservation // "null"), .owner, .group, .mode] | @tsv')
  fi
  if [ "$ok" = 0 ]; then
    log "$slot: starting without the scratch binds"
    write_env "$flags"
    return 0
  fi

  # Only this host writes the top level: the slot sees the subdirectories
  # alone, each as a mount point it cannot replace. 0700: what they hold
  # is owned by guest ids as host ids (idmapped), a setuid file included.
  chown 0:0 "$scratch"
  chmod 0700 "$scratch"
  local dir
  while IFS=$'\t' read -r path dir owner group mode; do
    if [ -L "$scratch/$dir" ]; then
      rm -f "$scratch/$dir"
    fi
    if [ ! -d "$scratch/$dir" ]; then
      install -d -m "$mode" -o "$owner" -g "$group" "$scratch/$dir"
    fi
    flags="$flags --bind=$scratch/$dir:$path:idmap"
  done < <(get '.paths[] | [.path, .dir, .owner, .group, .mode] | @tsv')
  write_env "$flags"
}

# write_env <flags>: the containers module's flags plus <flags>, or none.
write_env() {
  [ -n "$1" ] || return 0
  local run=/run/container-slots/$slot base
  # shellcheck source=/dev/null
  base=$(. "/etc/nixos-containers/$slot.conf" && printf '%s' "${EXTRA_NSPAWN_FLAGS-}")
  printf 'EXTRA_NSPAWN_FLAGS="%s%s"\n' "$base" "$1" >"$run/storage.env.new"
  mv "$run/storage.env.new" "$run/storage.env"
}

quotas() {
  local rds rq sds sq
  while IFS=$'\t' read -r rds rq sds sq; do
    if exists "$rds"; then set_quota "$rds" refquota "$rq"; fi
    if exists "$sds"; then set_quota "$sds" quota "$sq"; fi
  done < <(jq -r '.slots[] | [.rootDataset, (.rootQuota // "null"), .scratchDataset, (.scratchQuota // "null")] | @tsv' "$conf")
  local ds q r
  while IFS=$'\t' read -r ds q r; do
    if exists "$ds"; then
      set_quota "$ds" refquota "$q"
      set_quota "$ds" refreservation "$r"
    fi
  done < <(jq -r '.slots[].data[] | [.dataset, .quota, (.reservation // "null")] | @tsv' "$conf")
}

case "${1-}" in
  prepare)
    slot=${2:?usage: container-slot-storage prepare <slot>}
    prepare
    ;;
  quotas) quotas ;;
  *)
    echo "usage: container-slot-storage prepare <slot> | quotas" >&2
    exit 1
    ;;
esac
