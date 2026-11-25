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
# checks its own status.)
#
# quotas: applies the configured quotas to the datasets that exist.

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
  local ok=1
  ensure_dataset "$(get .rootDataset)" "$root" refquota "$(get .rootQuota)" || ok=0
  install -d -m 0700 "$(dirname "$scratch")"
  ensure_dataset "$(get .scratchDataset)" "$scratch" quota "$(get .scratchQuota)" || ok=0
  if [ "$ok" = 0 ]; then
    log "$slot: starting without the scratch binds"
    return 0
  fi

  # Only this host writes the top level: the slot sees the subdirectories
  # alone, each as a mount point it cannot replace. 0700: what they hold
  # is owned by guest ids as host ids (idmapped), a setuid file included.
  chown 0:0 "$scratch"
  chmod 0700 "$scratch"
  local flags="" path dir owner group mode
  while IFS=$'\t' read -r path dir owner group mode; do
    if [ -L "$scratch/$dir" ]; then
      rm -f "$scratch/$dir"
    fi
    if [ ! -d "$scratch/$dir" ]; then
      install -d -m "$mode" -o "$owner" -g "$group" "$scratch/$dir"
    fi
    flags="$flags --bind=$scratch/$dir:$path:idmap"
  done < <(get '.paths[] | [.path, .dir, .owner, .group, .mode] | @tsv')

  local base
  # shellcheck source=/dev/null
  base=$(. "/etc/nixos-containers/$slot.conf" && printf '%s' "${EXTRA_NSPAWN_FLAGS-}")
  printf 'EXTRA_NSPAWN_FLAGS="%s%s"\n' "$base" "$flags" >"$run/storage.env.new"
  mv "$run/storage.env.new" "$run/storage.env"
}

quotas() {
  local rds rq sds sq
  while IFS=$'\t' read -r rds rq sds sq; do
    if exists "$rds"; then set_quota "$rds" refquota "$rq"; fi
    if exists "$sds"; then set_quota "$sds" quota "$sq"; fi
  done < <(jq -r '.slots[] | [.rootDataset, (.rootQuota // "null"), .scratchDataset, (.scratchQuota // "null")] | @tsv' "$conf")
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
