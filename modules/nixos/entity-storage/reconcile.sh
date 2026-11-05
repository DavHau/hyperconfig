# entity-storage-reconcile [user...]: bring the managed users' datasets
# (all, or the named ones) to the configured layout. Idempotent. Never
# shadows data: a dataset is only created or mounted over an absent or
# empty directory; anything else is refused for that user (exit 1 at the
# end) and left to entity-storage-migrate.

exec 9>/run/entity-storage.lock
flock 9

ensure_parents

# Runs under `|| return`, where set -e is off: failures are checked
# explicitly.
# ensure_ds USER GROUP PATH DATASET QUOTA_PROP QUOTA MODE
# MODE "keep": keep the mode of an existing root; a new one takes the
# mode of the directory it replaces, else 0700.
ensure_ds() {
  local user=$1 group=$2 path=$3 ds=$4 qprop=$5 quota=$6 mode=$7
  local opts=() mp want cur
  if ds_exists "$ds"; then
    mp=$(zget mountpoint "$ds")
    if [ "$mp" != "$path" ]; then
      echo "$user: REFUSED: $ds has mountpoint $mp, expected $path; fix it by hand"
      return 1
    fi
    if [ "$(zget mounted "$ds")" != yes ]; then
      if ! absent_or_empty "$path"; then
        echo "$user: REFUSED: $path is not empty; not mounting $ds over it"
        return 1
      fi
      zfs mount "$ds" || return 1
      echo "$user: mounted $ds at $path"
      changed=1
    fi
  else
    if ! absent_or_empty "$path"; then
      echo "$user: REFUSED: $path is not empty and has no dataset; run entity-storage-migrate $user"
      return 1
    fi
    if [ "$mode" = keep ]; then
      if [ -d "$path" ]; then mode=$(stat -c %a "$path"); else mode=0700; fi
    fi
    # The home inherits /home/<user> from its parent.
    [ "$ds" = "$home_parent/$user" ] || opts+=(-o "mountpoint=$path")
    [ -z "$qprop" ] || opts+=(-o "$qprop=$quota")
    zfs create "${opts[@]}" "$ds" || return 1
    echo "$user: created $ds at $path"
    changed=1
  fi
  if [ -n "$qprop" ]; then
    want=$(bytes "$quota")
    cur=$(zget "$qprop" "$ds")
    if [ "$cur" != "$want" ]; then
      zfs set "$qprop=$quota" "$ds" || return 1
      echo "$user: set $qprop=$quota on $ds"
      changed=1
    fi
  fi
  if [ "$(findmnt -n -o SOURCE --mountpoint "$path")" != "$ds" ]; then
    echo "$user: ERROR: $path is not $ds after reconciling"
    return 1
  fi
  chown "$user:$group" "$path" || return 1
  [ "$mode" = keep ] || chmod "$mode" "$path" || return 1
}

reconcile_user() {
  local user=$1 home group hds sds i ok=0
  home=$(user_field "$user" home)
  group=$(user_field "$user" group)
  hds=$home_parent/$user
  sds=$scratch_parent/$user
  changed=0

  if ds_exists "$hds" && [ "$(zget "$migrating_prop" "$hds")" != - ]; then
    echo "$user: SKIPPED: entity-storage-migrate is working on it (or was interrupted; see $migrating_prop on $hds)"
    return 1
  fi
  # Nothing below the home before the home itself is right.
  ensure_ds "$user" "$group" "$home" "$hds" refquota "$(user_field "$user" homeQuota)" keep || return 1
  ensure_intermediates "$home" "$user" "$group" || return 1
  ensure_ds "$user" "$group" "$home/scratch" "$sds" quota "$(user_field "$user" scratchQuota)" 0700 || return 1
  for i in "${!sub_names[@]}"; do
    ensure_ds "$user" "$group" "$home/${sub_paths[$i]}" "$sds/${sub_names[$i]}" "" "" 0700 || ok=1
  done
  [ "$changed" = 1 ] || [ "$ok" != 0 ] || echo "$user: unchanged"
  return "$ok"
}

if [ $# -gt 0 ]; then
  users=("$@")
else
  mapfile -t users < <(jq -r '.users | keys[]' "$config")
fi

failed=0
for user in "${users[@]}"; do
  if ! is_managed "$user"; then
    echo "$user: not in hyper.entityStorage.users"
    failed=1
    continue
  fi
  reconcile_user "$user" || failed=1
done
exit "$failed"
