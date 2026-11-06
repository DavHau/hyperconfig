# entity-storage-migrate USER [--to-scratch RELPATH]... [--dry-run]
# entity-storage-migrate --finalize USER
#
# Moves an existing home onto its datasets (./default.nix): the backed-up
# home dataset, the scratch dataset (old ~/scratch plus --to-scratch
# paths, which stay reachable through relative symlinks) and the cache,
# containers and sbox-state datasets. The user's services, user manager
# and sessions are stopped meanwhile, and new logins refused (account
# expired), then restored afterwards. The old tree
# is kept as /home/.premigrate-USER until --finalize; any failure before
# the new home is verified puts everything back as it was.

usage() {
  cat <<EOF
usage: entity-storage-migrate USER [--to-scratch RELPATH]... [--dry-run]
       entity-storage-migrate --finalize USER
EOF
}

die() {
  echo "entity-storage-migrate: $*" >&2
  exit 1
}

human() {
  numfmt --to=iec-i --suffix=B "$1"
}

user=""
finalize=0
dry_run=0
to_scratch=()
while [ $# -gt 0 ]; do
  case $1 in
    --finalize) finalize=1 ;;
    --dry-run) dry_run=1 ;;
    --to-scratch)
      [ $# -ge 2 ] || die "--to-scratch needs a path"
      to_scratch+=("${2%/}")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$user" ] || die "one user at a time"
      user=$1
      ;;
  esac
  shift
done
[ -n "$user" ] || {
  usage >&2
  exit 1
}
[ "$(id -u)" = 0 ] || die "run as root"
# Our own cwd must not count as activity in the home.
cd /

is_managed "$user" || die "$user is not in hyper.entityStorage.users; add it there (quotas) and deploy first"
home=$(user_field "$user" home)
group=$(user_field "$user" group)
home_quota=$(user_field "$user" homeQuota)
scratch_quota=$(user_field "$user" scratchQuota)
hds=$home_parent/$user
sds=$scratch_parent/$user
old=$homes_dir/.premigrate-$user
tmp=$homes_dir/.migrate-$user

mounts_below() {
  findmnt -rn -o TARGET | awk -v p="$1" '$0 == p || index($0, p "/") == 1'
}

if [ "$finalize" = 1 ]; then
  [ "$dry_run" = 0 ] && [ ${#to_scratch[@]} = 0 ] || die "--finalize takes only the user"
  ds_exists "$hds" && [ "$(findmnt -n -o SOURCE --mountpoint "$home")" = "$hds" ] ||
    die "$home is not on $hds; nothing migrated to finalize"
  [ "$(zget "$migrating_prop" "$hds")" = - ] || die "the migration of $user did not complete"
  [ -d "$old" ] || die "$old does not exist"
  [ -z "$(mounts_below "$old")" ] || die "something is mounted below $old"
  rm -rf --one-file-system -- "$old"
  echo "removed $old; its blocks stay in the snapshots of $(findmnt -n -o SOURCE --target "$homes_dir") until those expire"
  exit 0
fi

### Checks: nothing changes before the stop.

if ds_exists "$hds" || ds_exists "$sds"; then
  if ds_exists "$hds" && [ "$(zget "$migrating_prop" "$hds")" != - ]; then
    die "an earlier migration of $user was interrupted ($migrating_prop is set on $hds). Check $home and $old, then remove the new datasets (zfs destroy -r $hds; zfs destroy -r $sds) and run again"
  fi
  die "$user already has datasets ($hds or $sds); nothing to migrate"
fi
[ ! -e "$old" ] && [ ! -L "$old" ] || die "$old exists (an earlier migration not finalized?)"
[ ! -e "$tmp" ] && [ ! -L "$tmp" ] || die "$tmp exists (left over from an interrupted run?); remove it"
[ -d "$home" ] && [ ! -L "$home" ] || die "$home is not a directory"
mountpoint -q "$home" && die "$home is already a mount point"
uid=$(id -u "$user")

# The paths that become mount points must be real directories (or absent).
for rel in scratch "${intermediates[@]}" "${sub_paths[@]}"; do
  p=$home/$rel
  [ ! -L "$p" ] || die "$p is a symlink; resolve it by hand first"
  [ ! -e "$p" ] || [ -d "$p" ] || die "$p is not a directory"
done

for i in "${!to_scratch[@]}"; do
  r=${to_scratch[$i]}
  case /$r/ in
    // | //* | */./* | */../*) die "--to-scratch $r: give a plain path relative to $home" ;;
    *[*?[\\]*) die "--to-scratch $r: no glob characters" ;;
    /scratch/* | /.cache/* | /.local/share/containers/* | /.local/state/sbox/*)
      die "--to-scratch $r: already in scratch"
      ;;
    /.local/ | /.local/share/ | /.local/state/) die "--to-scratch $r: holds scratch mount points" ;;
  esac
  p=$home
  IFS=/ read -ra parts <<<"$r"
  for part in "${parts[@]}"; do
    p=$p/$part
    [ ! -L "$p" ] || die "--to-scratch $r: $p is a symlink"
  done
  [ -e "$p" ] || die "--to-scratch $r: $p does not exist"
  [ ! -e "$home/scratch/$r" ] && [ ! -L "$home/scratch/$r" ] || die "--to-scratch $r: $home/scratch/$r exists"
  for j in "${!to_scratch[@]}"; do
    [ "$i" != "$j" ] || continue
    case ${to_scratch[$j]}/ in
      "$r"/*) die "--to-scratch $r overlaps ${to_scratch[$j]}" ;;
    esac
  done
done

[ -z "$(mounts_below "$home")" ] || die "mounted below $home (unmount or move these first):
$(mounts_below "$home")"

### Sizes.

echo "Measuring $home ..."
listing=$(du -x -B1 --max-depth=1 -- "$home" || true)
size_of() {
  local rel=$1
  [ -e "$home/$rel" ] || {
    echo 0
    return
  }
  if [[ $rel != */* ]]; then
    awk -F '\t' -v p="$home/$rel" '$2 == p { print $1 }' <<<"$listing"
  else
    { du -sx -B1 -- "$home/$rel" || true; } | cut -f1
  fi
}
total=$(awk -F '\t' -v p="$home" '$2 == p { print $1 }' <<<"$listing")
scratch_rels=(scratch "${sub_paths[@]}" "${to_scratch[@]}")
scratch_total=0
scratch_report=""
for rel in "${scratch_rels[@]}"; do
  s=$(size_of "$rel")
  s=${s:-0}
  scratch_total=$((scratch_total + s))
  [ "$s" = 0 ] || scratch_report+="    ~/$rel $(human "$s")"$'\n'
done
backed=$((total - scratch_total))
[ "$backed" -ge 0 ] || backed=0
home_quota_b=$(bytes "$home_quota")
scratch_quota_b=$(bytes "$scratch_quota")
avail=$(zget available "${home_parent%/*}")

echo "$home: $(human "$total")"
echo "  backed-up home ($hds, refquota $home_quota): $(human "$backed")"
echo "  scratch ($sds, quota $scratch_quota): $(human "$scratch_total")"
printf '%s' "$scratch_report"
echo "  pool space available: $(human "$avail")"

fits=1
if [ "$backed" -gt "$home_quota_b" ]; then
  fits=0
  echo
  echo "The backed-up part does not fit into $home_quota. Largest entries staying in it:"
  awk -F '\t' -v h="$home" '$2 != h' <<<"$listing" | sort -rn | while IFS=$'\t' read -r s p; do
    rel=${p#"$home"/}
    skip=0
    for x in "${scratch_rels[@]}"; do [ "$rel" != "$x" ] || skip=1; done
    [ "$skip" = 1 ] || printf '  %8s  %s\n' "$(human "$s")" "$rel"
  done | head -n 15 || true
  echo "Move some with --to-scratch RELPATH, or raise hyper.entityStorage.users.$user.homeQuota."
fi
if [ "$scratch_total" -gt "$scratch_quota_b" ]; then
  fits=0
  echo "The scratch part does not fit into $scratch_quota; raise hyper.entityStorage.users.$user.scratchQuota or clean up."
fi
if [ $((backed + scratch_total)) -ge "$avail" ]; then
  fits=0
  echo "The pool has no room for the copy (the old tree stays until --finalize)."
fi
[ "$fits" = 1 ] || exit 1

### Who is using the home.

units_of() {
  # Every loaded unit of a type, Id only.
  systemctl list-units --all --type="$1" --plain --no-legend --no-pager |
    awk -v t=".$1" '{ for (i = 1; i <= NF; i++) if (substr($i, length($i) - length(t) + 1) == t) { print $i; break } }'
}

# Services configured to run as the user, whether running or not (a
# Restart= or a timer would bring them back during the copy).
user_services() {
  local svcs
  mapfile -t svcs < <(units_of service)
  [ ${#svcs[@]} = 0 ] || systemctl show -p Id -p User -- "${svcs[@]}" |
    awk -v u="$user" -v uid="$uid" -v RS= -F '\n' '{
      id = ""; usr = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Id=/) id = substr($i, 4)
        if ($i ~ /^User=/) usr = substr($i, 6)
      }
      # user@<uid> (User=%i) is handled with linger and the sessions.
      if ((usr == u || usr == uid) && id != "user@" uid ".service") print id
    }'
}

# System services with a process of the user's uid that do not run as
# the user (root services that drop privileges), from the processes'
# cgroups. The user manager's and the sessions' processes live in
# user.slice and go with the user manager and terminate-user.
uid_cgroup_services() {
  local pid
  for pid in $(pgrep -U "$uid" || true); do
    sed -n 's|^0::||p' "/proc/$pid/cgroup" 2>/dev/null || true
  done | awk -F / '$2 == "system.slice" { for (i = NF; i > 2; i--) if ($i ~ /\.service$/) { print $i; break } }'
}

# Sockets and timers that start one of the services above. Accept=yes
# sockets spawn instances of their template, so its User= is read from a
# probe instance.
triggers_of_services() {
  local -A is_service=()
  local s socks timers probes=() id accept triggers t
  for s in "${services[@]}"; do is_service[$s]=1; done
  mapfile -t socks < <(units_of socket)
  mapfile -t timers < <(units_of timer)
  if [ ${#socks[@]} -gt 0 ]; then
    while IFS=$'\t' read -r id accept triggers; do
      if [ "$accept" = yes ]; then
        probes+=("${id%.socket}@entity-storage-probe.service")
      else
        for t in $triggers; do
          [ -z "${is_service[$t]:-}" ] || echo "$id"
        done
      fi
    done < <(systemctl show -p Id -p Accept -p Triggers -- "${socks[@]}" |
      awk -v RS= -F '\n' '{
        id = ""; a = ""; t = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Id=/) id = substr($i, 4)
          if ($i ~ /^Accept=/) a = substr($i, 8)
          if ($i ~ /^Triggers=/) t = substr($i, 10)
        }
        print id "\t" a "\t" t
      }')
  fi
  if [ ${#probes[@]} -gt 0 ]; then
    systemctl show -p Id -p User -- "${probes[@]}" |
      awk -v u="$user" -v uid="$uid" -v RS= -F '\n' '{
        id = ""; usr = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Id=/) id = substr($i, 4)
          if ($i ~ /^User=/) usr = substr($i, 6)
        }
        if (usr == u || usr == uid) { sub(/@entity-storage-probe\.service$/, ".socket", id); print id }
      }'
  fi
  if [ ${#timers[@]} -gt 0 ]; then
    while IFS=$'\t' read -r id triggers; do
      for t in $triggers; do
        [ -z "${is_service[$t]:-}" ] || echo "$id"
      done
    done < <(systemctl show -p Id -p Triggers -- "${timers[@]}" |
      awk -v RS= -F '\n' '{
        id = ""; t = ""
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^Id=/) id = substr($i, 4)
          if ($i ~ /^Triggers=/) t = substr($i, 10)
        }
        print id "\t" t
      }')
  fi
}

# Processes of any uid with their cwd or an open file in the home (one
# find over /proc; a shell loop over every fd is slow). Only processes
# with our root: a container's /home/<user> is another directory.
busy_in_home() {
  local root dirs=()
  root=$(stat -c %d:%i /)
  mapfile -t dirs < <(stat -L -c '%d:%i %n' /proc/[0-9]*/root 2>/dev/null |
    awk -v r="$root" '$1 == r { sub(/\/root$/, "", $2); print $2 "/cwd"; print $2 "/fd/" }')
  [ ${#dirs[@]} = 0 ] || find "${dirs[@]}" -maxdepth 1 \
    \( -lname "$home" -o -lname "$home/*" \) -printf '  %p -> %l\n' 2>/dev/null || true
}

mapfile -t services < <({
  user_services
  uid_cgroup_services
} | sort -u)
mapfile -t triggers < <(triggers_of_services | sort -u)
active_services=()
for s in "${services[@]}"; do
  ! systemctl is-active --quiet -- "$s" || active_services+=("$s")
done
active_triggers=()
for t in "${triggers[@]}"; do
  ! systemctl is-active --quiet -- "$t" || active_triggers+=("$t")
done
lingers=0
locked=0
[ ! -e "/var/lib/systemd/linger/$user" ] || lingers=1
manager=0
! systemctl is-active --quiet "user@$uid.service" || manager=1

echo
echo "Stopping for the copy (and starting again after it):"
for u in "${active_triggers[@]}" "${active_services[@]}"; do echo "  $u"; done
[ "$manager" = 0 ] || echo "  user@$uid.service"
[ "$lingers" = 0 ] || echo "  linger of $user (disabled meanwhile)"
echo "  every session of $user (loginctl terminate-user; not restored)"
if [ "$dry_run" = 1 ]; then
  echo
  echo "Dry run: nothing changed."
  exit 0
fi

### From here on, every exit goes through cleanup.

state_dir=/var/lib/entity-storage
stopped_file=$state_dir/stopped-$user
phase=checked
created=0
swapped=0

restore() {
  local u
  # First: user@ goes through PAM (systemd-user), which refuses an
  # expired account.
  [ "$locked" = 0 ] || chage -E "${expire:--1}" "$user" || echo "WARNING: could not restore the account expiry of $user (chage -E ${expire:--1} $user)"
  [ "$lingers" = 0 ] || loginctl enable-linger "$user" || echo "WARNING: loginctl enable-linger $user failed"
  [ "$manager" = 0 ] || systemctl start "user@$uid.service" || echo "WARNING: could not start user@$uid.service"
  for u in "${active_services[@]}" "${active_triggers[@]}"; do
    systemctl start -- "$u" || echo "WARNING: could not start $u"
  done
  rm -f "$stopped_file"
}

# Returns non-zero when the old home could not be put back; the user's
# units then stay stopped.
rollback() {
  echo "Rolling back."
  if [ "$swapped" = 1 ]; then
    zfs destroy -r "$sds" || echo "WARNING: zfs destroy -r $sds failed"
    zfs destroy -r "$hds" || echo "WARNING: zfs destroy -r $hds failed"
    if mountpoint -q "$home"; then
      echo "MANUAL: $home is still mounted; the old home is $old"
      return 1
    fi
    if [ -d "$home" ] && ! rmdir -- "$home"; then
      echo "MANUAL: $home is not empty; the old home is $old"
      return 1
    fi
    mv -T -- "$old" "$home" || {
      echo "MANUAL: could not move $old back to $home"
      return 1
    }
  elif [ "$created" = 1 ]; then
    zfs destroy -r "$sds" || echo "WARNING: zfs destroy -r $sds failed"
    zfs destroy -r "$hds" || echo "WARNING: zfs destroy -r $hds failed"
  fi
  rmdir -- "$tmp"/* "$tmp" 2>/dev/null || true
}

cleanup() {
  local status=$?
  set +e
  trap - EXIT INT TERM
  if [ "$phase" != finished ] && [ "$phase" != checked ]; then
    echo "entity-storage-migrate: failed (exit $status) in phase $phase" >&2
    if [ "$phase" = stopping ] || rollback; then
      restore
      echo "Restored what was stopped; $home is as before."
    else
      echo "Left $user's units stopped (list: $stopped_file); fix the above, then start them."
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

### Stop.

phase=stopping
mkdir -p "$state_dir"
{
  printf '%s\n' "${active_triggers[@]}" "${active_services[@]}"
  [ "$manager" = 0 ] || echo "user@$uid.service"
  [ "$lingers" = 0 ] || echo "linger"
} >"$stopped_file"
echo "Stopping; the list is in $stopped_file until it is restored."
# No new logins until restore: terminate-user alone loses to a client
# that reconnects every few seconds. An expired account is refused by
# sshd and by every PAM account check; the previous expiry comes back.
expire=$(getent shadow "$user" | cut -d: -f8)
chage -E 0 "$user"
locked=1
echo "expire ${expire:--1}" >>"$stopped_file"
for u in "${active_triggers[@]}"; do systemctl stop -- "$u"; done
for u in "${active_services[@]}"; do systemctl stop -- "$u"; done
[ "$lingers" = 0 ] || loginctl disable-linger "$user"
loginctl terminate-user "$user" 2>/dev/null || true
systemctl stop "user@$uid.service"
for _ in $(seq 30); do
  pgrep -U "$uid" >/dev/null || break
  sleep 1
done
if pgrep -U "$uid" >/dev/null; then
  die "processes of $user still run:
$(ps -o pid=,cmd= -U "$uid")"
fi
busy=$(busy_in_home)
[ -z "$busy" ] || die "processes still use $home:
$busy"
[ -z "$(mounts_below "$home")" ] || die "mounted below $home:
$(mounts_below "$home")"

### Copy into the new datasets at temporary mount points.

phase=copying
ensure_parents
install -d -m 0700 "$tmp"
created=1
zfs create -o mountpoint="$tmp/home" -o refquota="$home_quota" -o "$migrating_prop=yes" "$hds"
zfs create -o mountpoint="$tmp/scratch" -o quota="$scratch_quota" "$sds"
for i in "${!sub_names[@]}"; do
  zfs create -o mountpoint="$tmp/${sub_names[$i]}" "$sds/${sub_names[$i]}"
done

rs=(rsync -aHAXS --numeric-ids --one-file-system)
excludes=()
for rel in "${scratch_rels[@]}"; do excludes+=("--exclude=/$rel"); done
echo "Copying $home ..."
"${rs[@]}" "${excludes[@]}" -- "$home/" "$tmp/home/"
[ ! -d "$home/scratch" ] || "${rs[@]}" -- "$home/scratch/" "$tmp/scratch/"
for i in "${!sub_names[@]}"; do
  src=$home/${sub_paths[$i]}
  [ ! -d "$src" ] || "${rs[@]}" -- "$src/" "$tmp/${sub_names[$i]}/"
done
for r in "${to_scratch[@]}"; do
  "${rs[@]}" --relative -- "$home/./$r" "$tmp/scratch/"
  up=${r//[!\/]/}
  up=${up//\//../}
  ln -s -- "${up}scratch/$r" "$tmp/home/$r"
  chown -h "$user:$group" "$tmp/home/$r"
done
ensure_intermediates "$tmp/home" "$user" "$group"

### Swap.

phase=swapping
pgrep -U "$uid" >/dev/null && die "$user started a process during the copy:
$(ps -o pid=,cmd= -U "$uid")"
busy=$(busy_in_home)
[ -z "$busy" ] || die "processes started using $home during the copy:
$busy"
[ -z "$(mounts_below "$home")" ] || die "something was mounted below $home during the copy"

mv -T -- "$home" "$old"
swapped=1
zfs inherit mountpoint "$hds"
zfs set mountpoint="$home/scratch" "$sds"
for i in "${!sub_names[@]}"; do
  zfs set mountpoint="$home/${sub_paths[$i]}" "$sds/${sub_names[$i]}"
done
# zfs may or may not have removed the old mount point directories.
find "$tmp" -mindepth 1 -maxdepth 1 -type d -empty -delete
rmdir -- "$tmp"
zfs inherit "$migrating_prop" "$hds"
entity-storage-reconcile "$user"

### Verify.

phase=verifying
# Entries and the bytes of everything but directories (whose sizes differ
# between filesystems).
tally() {
  find "$@" -printf '%y %s\n' | awk '{ n++; if ($1 != "d") s += $2 } END { print n + 0, s + 0 }'
}
read -r old_n old_s < <(tally "$old" -xdev)
read -r new_n new_s < <(tally "$home")
# New: mount point directories that did not exist before, a symlink and
# the implied parent directories in scratch per --to-scratch path.
slack_n=$((${#sub_paths[@]} + ${#intermediates[@]} + 1))
slack_s=0
for r in "${to_scratch[@]}"; do
  up=${r//[!\/]/}
  slack_n=$((slack_n + 2 * ${#up} + 1))
  slack_s=$((slack_s + ${#up} * 3 + 8 + ${#r}))
done
echo "old: $old_n entries, $(human "$old_s"); new: $new_n entries, $(human "$new_s")"
[ "$new_n" -ge "$old_n" ] && [ "$new_n" -le $((old_n + slack_n)) ] ||
  die "entry counts differ beyond the expected mount points and symlinks"
[ "$new_s" -ge "$old_s" ] && [ "$new_s" -le $((old_s + slack_s)) ] ||
  die "sizes differ"
[ "$(stat -c %U "$home")" = "$user" ] || die "$home is not owned by $user"

### Restore.

phase=finished
restore
echo
echo "Migrated $user: $home is on $hds, scratch on $sds."
echo "The old tree is $old. Once $user's services and data check out:"
echo "  entity-storage-migrate --finalize $user"
