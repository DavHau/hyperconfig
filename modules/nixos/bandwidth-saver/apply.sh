# bandwidth-saver-apply on|off, the root half of the bandwidth-saving mode:
# run by bandwidth-saver.service (ExecStart = on, ExecStopPost = off). Config: $BWS_CONFIG
# (JSON from ./default.nix). State: /run/bandwidth-saver (gone after a reboot).
#
# Deliberately no `set -e`: `off` must undo as much as it can even if
# one step fails, and `on` must never leave a half-applied state without
# its record (every step is recorded before it is taken).
set -u -o pipefail

config=${BWS_CONFIG:?}
state=/run/bandwidth-saver
guard_name=50-bandwidth-saver.conf
flag=$state/active

log() { printf 'bandwidth-saver: %s\n' "$*"; }

# Units that exist (LoadState=loaded) in the system / a user's manager.
sys_loaded() { [ "$(systemctl show -P LoadState "$1" 2>/dev/null)" = loaded ]; }
usr() { local u=$1; shift; systemctl --user -M "$u@" "$@"; }
as_user() { local u=$1; shift; setpriv --reuid="$(id -u "$u")" --regid="$(id -g "$u")" --init-groups -- "$@"; }
# A shell inside container $1 (its own root and mounts): paths under its
# /run are never walked from the host, so its symlinks can't point root
# at the host's files.
in_ctr() { local c=$1; shift; systemd-run -M "$c" --wait --quiet --collect --expand-environment=no -- /run/current-system/sw/bin/sh -c "$@"; }
usr_loaded() { [ "$(usr "$1" show -P LoadState "$2" 2>/dev/null)" = loaded ]; }

# A listed .service drags its .timer along.
expand() {
  local u
  for u in "$@"; do
    printf '%s\n' "$u"
    case $u in *.service) printf '%s\n' "${u%.service}.timer" ;; esac
  done
}
mapfile -t sys_units < <(jq -r '.systemUnits[]' "$config" | while read -r u; do expand "$u"; done)
mapfile -t usr_units < <(jq -r '.userUnits[]' "$config" | while read -r u; do expand "$u"; done)
# "<container> <unit>" pairs.
mapfile -t ctr_units < <(jq -r '.containerUnits | to_entries[] | .key as $c | .value[] | "\($c) \(.)"' "$config" |
  while read -r c u; do expand "$u" | sed "s/^/$c /"; done)

# Users whose systemd --user manager runs now.
running_users() {
  local d uid
  for d in /run/user/*; do
    uid=${d##*/}
    [ -S "$d/systemd/private" ] || continue
    id -nu "$uid" 2>/dev/null
  done
}

# The guard: a runtime drop-in that makes a start of the unit a no-op
# (failed condition, not a failure) while saving. It keeps a deploy's
# switch (which re-starts active targets), chores-on-ac (which starts
# chores-allowed.target), Restart= and timers from bringing units back.
# A drop-in, not `systemctl mask --runtime`: NixOS units live in
# /etc/systemd/system, which takes precedence over a mask in
# /run/systemd/system; *.control drop-ins apply on top of every unit.
guard_text='[Unit]
ConditionPathExists=!/run/bandwidth-saver/active
'

on() {
  if [ -e "$flag" ]; then log "already on"; return 0; fi
  # A killed `off` left its record: finish it first, so nothing is lost.
  if [ -d "$state" ]; then log "finishing an interrupted off"; off; fi
  rm -rf "$state"
  mkdir -p "$state"
  : > "$state/system-active"; : > "$state/system-guarded"
  : > "$state/user-active"; : > "$state/user-guarded"
  : > "$state/zerotier-left"
  : > "$state/container-active"
  touch "$flag"

  local u user d
  for u in "${sys_units[@]}"; do
    sys_loaded "$u" || continue
    d=/run/systemd/system.control/$u.d
    mkdir -p "$d" && printf '%s' "$guard_text" > "$d/$guard_name" && echo "$u" >> "$state/system-guarded"
    if systemctl is-active --quiet "$u"; then echo "$u" >> "$state/system-active"; fi
  done
  systemctl daemon-reload

  mapfile -t users < <(running_users)
  for user in "${users[@]}"; do
    local uid
    uid=$(id -u "$user")
    for u in "${usr_units[@]}"; do
      usr_loaded "$user" "$u" || continue
      d=/run/user/$uid/systemd/user.control/$u.d
      # As the user: the directory is theirs, root must not follow their symlinks.
      echo "$user $u" >> "$state/user-guarded"
      as_user "$user" "$BASH" -c 'mkdir -p "$1" && printf "%s" "$2" > "$1/$3"' _ "$d" "$guard_text" "$guard_name" ||
        log "guarding $user's $u failed"
      if usr "$user" is-active --quiet "$u"; then echo "$user $u" >> "$state/user-active"; fi
    done
    if grep -q "^$user " "$state/user-guarded"; then usr "$user" daemon-reload; fi
  done

  # Stop timers before their services, so none fires in between.
  local list
  list=$( (grep '\.timer$' "$state/system-guarded"; grep -v '\.timer$' "$state/system-guarded") | tr '\n' ' ')
  # shellcheck disable=SC2086
  [ -n "$list" ] && systemctl stop $list
  while read -r user u; do usr "$user" stop "$u"; done < <(sort -k2,2r "$state/user-guarded")

  # Containers: only units active now are stopped and held (a drop-in in
  # the container's own /run whose condition never holds).
  local c cu
  for cu in "${ctr_units[@]}"; do
    read -r c u <<< "$cu"
    systemctl -M "$c" is-active --quiet "$u" 2>/dev/null || continue
    echo "$c $u" >> "$state/container-active"
    in_ctr "$c" 'mkdir -p "$1" && printf "[Unit]\nConditionPathExists=!/\n" > "$1/$2"' _ \
      "/run/systemd/system.control/$u.d" "$guard_name" || log "guarding $u in $c failed"
  done
  local ctrs
  mapfile -t ctrs < <(cut -d' ' -f1 "$state/container-active" | sort -u)
  for c in "${ctrs[@]}"; do
    systemctl -M "$c" daemon-reload
    # shellcheck disable=SC2046
    systemctl -M "$c" stop $(awk -v c="$c" '$1 == c { print $2 }' "$state/container-active")
  done

  if [ "$(jq -r '.zerotier.enable' "$config")" = true ] && command -v zerotier-cli >/dev/null; then
    local nwid
    for nwid in $(zerotier-cli -j listnetworks 2>/dev/null | jq -r '.[].nwid'); do
      if jq -e --arg n "$nwid" '.zerotier.keepNetworks | index($n)' "$config" >/dev/null; then continue; fi
      echo "$nwid" >> "$state/zerotier-left"
      zerotier-cli leave "$nwid" >/dev/null || log "leaving zerotier network $nwid failed"
    done
  fi

  if [ "$(jq -r '.yggdrasil.enable' "$config")" = true ] && systemctl is-active --quiet yggdrasil.service; then
    ygg_saver
  fi
  log "on: stopped $(wc -l < "$state/system-active") system, $(wc -l < "$state/user-active") user and $(wc -l < "$state/container-active") container units, left $(wc -l < "$state/zerotier-left") zerotier networks"
}

# yggdrasil with only the kept peerings: no multicast, no listener (other
# machines' static peerings to us would otherwise come back inbound), the
# static peers cut to .yggdrasil.peers. Same key, same address, so the
# overlay and every session over it stay. If none of the kept peers comes
# up within the timeout, fall back to the normal config: reachability
# beats savings.
ygg_drop=/run/systemd/system.control/yggdrasil.service.d/$guard_name
ygg_root=/nix/var/nix/gcroots/bandwidth-saver-yggdrasil
ygg_saver() {
  # Recorded first: an interrupted `on` is undone by `off`.
  echo 1 > "$state/yggdrasil"
  # The drop-in names a store path: keep it alive while saving, even if a
  # deploy plus a GC drop the generation that brought it.
  ln -sfn "$(jq -r '.yggdrasil.conf' "$config")" "$ygg_root"
  mkdir -p "${ygg_drop%/*}"
  printf '[Service]\nExecStart=\nExecStart=%s\n' "$(jq -r '.yggdrasil.start' "$config")" > "$ygg_drop"
  systemctl daemon-reload
  ygg_restart
  local timeout i
  timeout=$(jq -r '.yggdrasil.upTimeout' "$config")
  for ((i = 0; i < timeout; i++)); do
    if ygg_peer_up; then
      log "yggdrasil: saver peerings up after ${i}s"
      return 0
    fi
    systemctl is-failed --quiet yggdrasil.service && break
    sleep 1
  done
  log "yggdrasil: no kept peer came up within ${timeout}s, back to the full mesh"
  ygg_normal
}
ygg_peer_up() { yggdrasilctl -json getPeers 2>/dev/null | jq -e '[.peers[] | select(.up)] | length > 0' >/dev/null; }
# Restart=always with systemd's start limit: a crash loop or fast toggling
# can leave the unit start-limit-hit, which no Restart= recovers.
ygg_restart() {
  systemctl reset-failed yggdrasil.service 2>/dev/null
  systemctl restart yggdrasil.service
}
ygg_normal() {
  rm -f "$ygg_drop" "$state/yggdrasil" "$state/ygg-misses" "$ygg_root"
  rmdir "${ygg_drop%/*}" 2>/dev/null
  systemctl daemon-reload
  ygg_restart
  local i
  for ((i = 0; i < 30; i++)); do
    systemctl is-active --quiet yggdrasil.service && return 0
    sleep 1
  done
  log "yggdrasil did not come back, restarting it again"
  ygg_restart
  systemctl is-active --quiet yggdrasil.service || log "yggdrasil is still not active"
}

# Every minute while the cut is on (bandwidth-saver-ygg-check.timer): the
# edi-only overlay has one point of failure, so after `checkMisses`
# minutes without an up peering go back to the full mesh (the rest of the
# saver stays on).
check() {
  [ -e "$state/yggdrasil" ] || return 0
  if ygg_peer_up; then rm -f "$state/ygg-misses"; return 0; fi
  local n
  n=$(( $(cat "$state/ygg-misses" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$state/ygg-misses"
  if [ "$n" -ge "$(jq -r '.yggdrasil.checkMisses' "$config")" ]; then
    log "yggdrasil: no kept peer for $n checks, back to the full mesh"
    ygg_normal
  fi
}

off() {
  [ -d "$state" ] || { log "already off"; return 0; }
  rm -f "$flag"
  local u user d

  # Also without the record: a drop-in left behind would pin every later
  # yggdrasil start to the cut config.
  if [ -e "$state/yggdrasil" ] || [ -e "$ygg_drop" ]; then ygg_normal; fi

  if [ -s "$state/zerotier-left" ]; then
    local nwid
    while read -r nwid; do
      zerotier-cli join "$nwid" >/dev/null || log "rejoining zerotier network $nwid failed"
    done < "$state/zerotier-left"
  fi

  while read -r u; do
    rm -f "/run/systemd/system.control/$u.d/$guard_name"
    rmdir "/run/systemd/system.control/$u.d" 2>/dev/null
  done < "$state/system-guarded"
  systemctl daemon-reload
  # Exactly what was running before. A timer wanted by a target other
  # than timers.target (chores-on-ac's chores-allowed.target) follows that
  # target's state now instead: plugged in or unplugged while saving.
  local start=() t gated up want
  while read -r u; do
    want=
    grep -qxF "$u" "$state/system-active" && want=1
    if [[ $u == *.timer ]]; then
      gated='' up=''
      for t in $(systemctl show -P WantedBy "$u"); do
        [ "$t" = timers.target ] && continue
        gated=1
        systemctl is-active --quiet "$t" && up=1
      done
      [ -n "$gated" ] && want=$up
    fi
    [ -n "$want" ] && start+=("$u")
  done < "$state/system-guarded"
  # Services first, then timers (a timer elapsed meanwhile fires at once).
  for u in "${start[@]}"; do case $u in *.timer) ;; *) systemctl start --no-block "$u" || log "starting $u failed" ;; esac; done
  for u in "${start[@]}"; do case $u in *.timer) systemctl start "$u" || log "starting $u failed" ;; esac; done

  local c ctrs
  mapfile -t ctrs < <(cut -d' ' -f1 "$state/container-active" | sort -u)
  for c in "${ctrs[@]}"; do
    while read -r cc u; do
      [ "$cc" = "$c" ] || continue
      in_ctr "$c" 'rm -f "$1/$2"; rmdir "$1" 2>/dev/null; true' _ "/run/systemd/system.control/$u.d" "$guard_name"
    done < "$state/container-active"
    systemctl -M "$c" daemon-reload
    # shellcheck disable=SC2046
    systemctl -M "$c" start $(awk -v c="$c" '$1 == c { print $2 }' "$state/container-active") || log "restarting units in $c failed"
  done

  local users
  mapfile -t users < <(cut -d' ' -f1 "$state/user-guarded" | sort -u)
  for user in "${users[@]}"; do
    local uid
    uid=$(id -u "$user") || continue
    while read -r gu u; do
      [ "$gu" = "$user" ] || continue
      as_user "$user" "$BASH" -c 'rm -f "$1/$2"; rmdir "$1" 2>/dev/null; true' _ \
        "/run/user/$uid/systemd/user.control/$u.d" "$guard_name"
    done < "$state/user-guarded"
    usr "$user" daemon-reload
    while read -r gu u; do
      [ "$gu" = "$user" ] && { usr "$user" start --no-block "$u" || log "starting $user's $u failed"; }
    done < "$state/user-active"
  done

  rm -rf "$state"
  log "off: restored"
}

# One at a time (on/off from the unit, check from its timer).
exec 9> /run/bandwidth-saver.lock
flock 9
case "${1:-}" in
  on) on ;;
  off) off ;;
  check) check ;;
  *) echo "usage: bandwidth-saver-apply {on|off|check}" >&2; exit 2 ;;
esac
