# nixpkgs-bump-busy: is an earlier nightly bump still going? The unit is
# only a client; the run is a turn in the gateway (../nixpkgs-bump.nix),
# so the answer is in the agent's state.db: a bump session (cwd @cwd@,
# not a subagent's) with a turn queued or started, active in the last
# 12 h (a row stuck longer than that blocks nothing).
#
# Exit 0 and one line saying which session: busy, the new run must not
# start. Exit 1: not busy, or state.db unreadable (then the run starts: a
# broken check must not stop every night; the reason goes to stderr).
db=@stateDb@
if ! rows=$(sqlite3 -readonly -bail -noheader -cmd '.timeout 30000' "file:$db?mode=ro" \
  "select s.id from sessions s join session_admissions a on a.target_session_id = s.id
   where s.cwd = '@cwd@' and coalesce(s.source, '') <> 'subagent'
     and a.status in ('queued', 'started')
     and coalesce(s.last_activity_at, s.started_at) > strftime('%s', 'now') - 12 * 3600
   group by s.id" 2>&1); then
  echo "nixpkgs-bump-busy: cannot read $db: $rows" >&2
  exit 1
fi
[ -n "$rows" ] || exit 1
echo "bump session ${rows//$'\n'/ } still has a turn in the gateway"
