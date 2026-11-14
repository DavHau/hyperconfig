# shellcheck shell=bash
# Restart greetd when the running greetd is definitely an old one and
# seat0 is idle: a greeter session is on it (not closing) and no other
# session holds it. See greetd.nix for why.
# Usage: greetd-idle-restart.sh [--quiet]   (--quiet: say nothing when
# there is nothing to do; the path unit and timer use it)
# Fail safe: any doubt (a probe failing, logind restarting in the same
# switch, greetd not exec'd yet at boot, no greeter on seat0 because a
# login is in progress) means "do nothing", and the script always exits
# 0, so it doesn't fail a switch (only a hang past the units' 30 s
# TimeoutStartSec would show as a failed unit).
# If a restart can't fix the mismatch (greetd comes back stale), the
# 10-min timer restarts the idle greeter again once per 10 min: bounded
# by the stamp below, and logged each time.
set +e +u
set +o pipefail
trap 'exit 0' EXIT

quiet=
[ "$1" = --quiet ] && quiet=1
say() { [ -n "$quiet" ] || echo "$@"; }
# Overridable for the fake-input check only.
proc=${GREETD_IDLE_RESTART_PROC:-/proc}
recheck_delay=${GREETD_IDLE_RESTART_RECHECK_DELAY:-2}
stamp=${GREETD_IDLE_RESTART_STAMP:-/run/greetd-idle-restart.stamp}

# stale: true iff the running greetd is definitely not the configured
# one (sets have_exe); otherwise says why not.
stale() {
  systemctl is-active -q greetd.service || { say "greetd not active"; return 1; }
  pid=$(systemctl show -p MainPID --value greetd.service 2>/dev/null)
  case $pid in '' | 0 | *[!0-9]*) say "greetd has no main pid"; return 1 ;; esac

  # ExecStart as configured now: "{ path=/nix/store/...-greetd-X/bin/greetd ;
  # argv[]=<that path> --config /nix/store/...-greetd.toml ; ... }"
  execstart=$(systemctl show -p ExecStart --value greetd.service 2>/dev/null)
  want_exe=$(printf '%s\n' "$execstart" | sed -n 's/^{ path=\([^ ;]*\) ;.*/\1/p')
  want_cmd=$(printf '%s\n' "$execstart" | sed -n 's/.*argv\[\]=\([^;]*\) ;.*/\1/p' | sed 's/ *$//')
  case $want_exe in /nix/store/*/bin/greetd) ;; *) say "cannot parse ExecStart"; return 1 ;; esac

  # The running binary. At boot greetd is Type=idle, so its MainPID can
  # still be systemd-executor: anything but a greetd binary means "not
  # ours to judge". A garbage-collected old binary reads "... (deleted)".
  have_exe=$(readlink "$proc/$pid/exe" 2>/dev/null)
  have_exe=${have_exe% (deleted)}
  case $have_exe in /nix/store/*/bin/greetd) ;; *) say "pid $pid is not greetd ($have_exe)"; return 1 ;; esac
  have_cmd=$(tr '\0' ' ' 2>/dev/null < "$proc/$pid/cmdline" | sed 's/ *$//')
  [ -n "$have_cmd" ] || { say "cannot read greetd's command line"; return 1; }

  if [ "$have_exe" = "$want_exe" ] && [ "$have_cmd" = "$want_cmd" ]; then
    say "greetd is current"
    return 1
  fi
  return 0
}

# idle: true iff logind answers, a greeter-class session on seat0 is
# there and not closing, and every other seat0 session is closing. No
# greeter on seat0 means a login is in progress (the greeter's session
# has ended, the user's doesn't exist yet): busy. A loginctl, jq or
# show-session failure counts as busy too.
idle() {
  sessions=$(loginctl list-sessions --json=short 2>/dev/null) || {
    echo "greetd is stale, but loginctl failed; not restarting"
    return 1
  }
  rows=$(printf '%s' "$sessions" \
    | jq -r '.[] | select(.seat == "seat0") | "\(.session) \(.class)"' \
    2>/dev/null) || {
    echo "greetd is stale, but the session list did not parse; not restarting"
    return 1
  }
  greeter=''
  busy=''
  while read -r id class; do
    [ -n "$id" ] || continue
    state=$(loginctl show-session -p State --value "$id" 2>/dev/null) || state=
    if [ "$class" = greeter ]; then
      case $state in '' | closing) ;; *) greeter=$id ;; esac
    else
      # A session left "closing" (its compositor is gone, a straggler
      # process keeps it listed) does not hold the seat; anything else,
      # or a state we cannot read, does.
      [ "$state" = closing ] || busy="$busy $id(${state:-unknown})"
    fi
  done <<EOF
$rows
EOF
  if [ -n "$busy" ]; then
    say "greetd is stale but seat0 is in use, not restarting:$busy"
    return 1
  fi
  if [ -z "$greeter" ]; then
    say "greetd is stale but no greeter is on seat0 (login in progress?), not restarting"
    return 1
  fi
  return 0
}

stale || exit 0
idle || exit 0
# Re-check after a moment: a login that is just starting (the greeter
# handing over to the user's session) must not be killed.
sleep "$recheck_delay"
stale || exit 0
idle || exit 0

# Loop guard: the path unit fires again after each restart. If a restart
# did not make greetd current (a mismatch this script cannot fix), don't
# restart again for 10 min.
if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
  echo "greetd is stale ($have_exe), but it was restarted <10 min ago; not again"
  exit 0
fi
touch "$stamp" 2>/dev/null
echo "greetd is stale ($have_exe) and seat0 is idle, restarting it"
systemctl restart --no-block greetd.service
exit 0
