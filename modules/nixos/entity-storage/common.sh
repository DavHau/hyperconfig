# Shared by entity-storage-reconcile and entity-storage-migrate.
# ENTITY_STORAGE_CONFIG is the JSON ./default.nix writes: the parent
# datasets and, per managed user, home, group and quotas.

config=$ENTITY_STORAGE_CONFIG
home_parent=$(jq -r .homeParent "$config")
homes_dir=$(jq -r .homesDir "$config")
scratch_parent=$(jq -r .scratchParent "$config")

# Scratch children: dataset name below the user's scratch dataset, path
# below the home.
sub_names=(cache containers sbox-state)
sub_paths=(.cache .local/share/containers .local/state/sbox)
# Directories zfs would otherwise create root-owned above sub_paths.
intermediates=(.local .local/share .local/state)

# Set on the home dataset while entity-storage-migrate works on it; the
# reconciler leaves such a user alone.
migrating_prop=hyper:entity-storage-migrating

is_managed() {
  jq -e --arg u "$1" '.users | has($u)' "$config" >/dev/null
}

user_field() {
  jq -r --arg u "$1" --arg f "$2" '.users[$u][$f]' "$config"
}

ds_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

zget() {
  zfs get -H -p -o value "$1" "$2"
}

bytes() {
  numfmt --from=iec "$1"
}

# Absent, or an empty real directory that nothing is mounted on: the only
# places a dataset may be created or mounted without shadowing data.
absent_or_empty() {
  local p=$1
  if [ -L "$p" ]; then
    return 1
  elif [ ! -e "$p" ]; then
    return 0
  fi
  [ -d "$p" ] && ! mountpoint -q "$p" && [ -z "$(ls -A -- "$p")" ]
}

# Parents carry no data: canmount=off. The home parent's mountpoint is
# inherited by the per-user homes; scratch children set their own.
ensure_parent() {
  local ds=$1 mp=$2
  if ds_exists "$ds"; then
    if [ "$(zget canmount "$ds")" != off ] || [ "$(zget mountpoint "$ds")" != "$mp" ]; then
      echo "$ds exists but is not canmount=off mountpoint=$mp; fix it by hand" >&2
      return 1
    fi
  else
    zfs create -o canmount=off -o mountpoint="$mp" "$ds"
    echo "created $ds"
  fi
}

ensure_parents() {
  ensure_parent "$home_parent" "$homes_dir" && ensure_parent "$scratch_parent" none
}

# ~/.local and below, owned by the user: zfs creates missing mountpoint
# directories as root, which would lock the user out of ~/.local.
ensure_intermediates() {
  local home=$1 user=$2 group=$3 d
  for d in "${intermediates[@]}"; do
    if [ ! -e "$home/$d" ] && [ ! -L "$home/$d" ]; then
      install -d -m 0700 -o "$user" -g "$group" "$home/$d"
    elif [ -d "$home/$d" ] && [ ! -L "$home/$d" ] && [ "$(stat -c %u "$home/$d")" = 0 ]; then
      chown "$user:$group" "$home/$d"
    fi
  done
}
