# nixpkgs-bump-follow <session-id> <log>: the nightly bump's client lost
# its turn (../nixpkgs-bump.nix says how: the gateway dropped the client's
# websocket on a keepalive timeout under load, or restarted). The turn
# lives in the gateway, not in the client, so this follows the session
# itself, by its rows in the agent's state.db (read-only):
#
#   1. wait until the session has no turn queued or running;
#   2. if one of its replies is the run's report (its last non-empty line
#      a NIXPKGS-BUMP line), append that reply to the log: done;
#   3. otherwise the turn was cut off (a gateway restart interrupts it and
#      never re-runs it; a lost one is fenced `unknown`): acknowledge an
#      unknown turn, then resume the session with a short message that
#      says so, at most @maxResumes@ times, and go back to 1.
#
# Exit 0 when the log now ends with the merged or unchanged verdict
# (nixpkgs-bump-verdict decides), 1 otherwise. Never sends the original
# prompt again: the session holds it, and the agent picks up its own
# workspace and logs (the skill's liveness stamp keeps the next night out
# while it is quiet, and the unit stays active while this waits).
set -uo pipefail

[ $# = 2 ] || { echo "usage: nixpkgs-bump-follow <session-id> <log>" >&2; exit 2; }
sid=$1
log=$2
case "$sid" in
  *[!A-Za-z0-9_-]*) echo "nixpkgs-bump-follow: bad session id" >&2; exit 2 ;;
esac

db="file:@hermesHome@/state.db?mode=ro"
hermes=/run/current-system/sw/bin/hermes
unit="@gatewayUnit@"
max_resumes="@maxResumes@"
poll="@pollSec@"

say() { echo "nixpkgs-bump-follow: $*" | tee -a "$log" >&2; }

q() { sqlite3 -readonly -bail -noheader -cmd '.timeout 30000' "$db" "$1"; }

# The run's session and the rows a compaction continued it in (never its
# subagents' sessions).
lineage="with recursive l(id) as (select '$sid' union
  select s.id from sessions s join l on s.parent_session_id = l.id
  where coalesce(s.source, '') <> 'subagent') select id from l"

# Unreadable (a wrong path, a lock held for minutes): counts as busy,
# at most @maxDbErrors@ polls in a row, then the follower gives up.
db_errors=0
busy() {
  local n
  if ! n=$(q "select count(*) from session_admissions
         where target_session_id in ($lineage) and status in ('queued', 'started')"); then
    db_errors=$((db_errors + 1))
    say "cannot read the session's state ($db_errors/@maxDbErrors@)"
    [ "$db_errors" -lt @maxDbErrors@ ] || return 2
    return 0
  fi
  db_errors=0
  [ "$n" != 0 ]
}

unknown() {
  local n
  n=$(q "select count(*) from session_admissions
         where target_session_id in ($lineage) and status = 'unknown'") || return 1
  [ "$n" != 0 ]
}

# The newest reply that is the run's report, if any.
report() {
  local ids id text
  ids=$(q "select id from messages where session_id in ($lineage) and active = 1
           and role = 'assistant' and coalesce(content, '') <> '' order by id desc limit 200") || return 1
  for id in $ids; do
    text=$(q "select content from messages where id = $id") || return 1
    if printf '%s\n' "$text" | grep -v -e '^[[:space:]]*$' | tail -n 1 |
      grep -qx -e 'NIXPKGS-BUMP: merged' -e 'NIXPKGS-BUMP: unchanged' -e 'NIXPKGS-BUMP: failed'; then
      printf '%s\n' "$text"
      return 0
    fi
  done
  return 1
}

# Sleeps one second at a time (no long sleeps), $1 seconds in all.
pause() { local i; for ((i = 0; i < $1; i++)); do sleep 1; done; }

wait_idle() {
  local rc
  say "waiting for session $sid to finish its turn in the gateway"
  while :; do
    busy
    rc=$?
    [ "$rc" = 0 ] || break
    pause "$poll"
  done
  [ "$rc" = 1 ]
}

wait_gateway() {
  local i
  for ((i = 0; i < 600; i++)); do
    systemctl is-active -q "$unit" && return 0
    sleep 1
  done
  return 1
}

continue_msg=$(mktemp)
trap 'rm -f "$continue_msg"' EXIT
cat >"$continue_msg" <<'EOF'
The nightly runner lost this turn: the gateway disconnected or restarted
while you worked, so your last turn was cut off (background processes it
started may have been killed). Continue the nixpkgs bump from where you
were: check your workspace, logs and builds as they are now, redo what
did not finish, and follow the nixpkgs-bump skill to the report. Never
deploy. End with the skill's NIXPKGS-BUMP line.
EOF

resumes=0
while :; do
  wait_idle || { say "cannot read state.db; giving up"; break; }
  if text=$(report); then
    say "the session's report:"
    printf '%s\n\nsession_id: %s\n' "$text" "$sid" >>"$log"
    break
  fi
  if [ "$resumes" -ge "$max_resumes" ]; then
    say "no report after $resumes resumes; giving up"
    break
  fi
  resumes=$((resumes + 1))
  wait_gateway || { say "$unit is not running; giving up"; break; }
  if unknown; then
    say "acknowledging the lost turn (hermes sessions discard)"
    "$hermes" sessions discard "$sid" --yes >>"$log" 2>&1 || say "discard failed"
  fi
  say "no report yet: resuming session $sid ($resumes/$max_resumes)"
  "$hermes" chat -Q --resume "$sid" --query-file "$continue_msg" >>"$log" 2>&1 ||
    say "resumed client exited $?"
  # Its own verdict ends it (failed too: already in the log); a lost
  # client again: the next round waits for the turn and looks.
  last=$(@verdict@ "$log") && exit 0
  case "$last" in "NIXPKGS-BUMP: "*) exit 1 ;; esac
done
@verdict@ "$log" >/dev/null
