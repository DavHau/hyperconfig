/*
  One unattended agent job of the infra-space agent: a systemd timer and
  oneshot in the guest that start `hermes chat -Q -s <skill>` through the
  agent's shim, with a log per run and a verdict taken from the report's
  last line. The mechanism of the nightly bump (./nixpkgs-bump.nix) and the
  security jobs (./security-jobs.nix); its header says why a timer and not
  hermes' cron, and why the unit does not own the run (stopping it kills
  the client only; the turn goes on in the gateway).

  A function, not a module: `import ./agent-job.nix { inherit config
  inputs lib pkgs; } { name = ...; ... }` returns the module fragment (unit, timer).

    name         unit name; also the skill's verdict prefix's default
    skill        the skill preloaded with -s
    description  the unit's
    calendar     OnCalendar, with an explicit time zone (the guest is UTC)
    prompt       text of the query
    promptHook   shell run before the query is written; may append lines
                 to "$query" (the bump's CM_PI_BUILD)
    busyCheck    shell run first (after the client lock): exit 0 means an
                 earlier run is still going, and this one starts nothing.
                 It writes a log ending `<verdictTag>: skipped` (put
                 `skipped` in okVerdicts) and exits 0 the first time; skipped again the next run
                 (the earlier one hangs), the unit fails, so the brief and
                 OnFailure= say so. The bump's: an earlier run's turn still
                 in the gateway
    verdictTag   the report's last line is `<verdictTag>: <word>`
    okVerdicts   words that count as a good run (anything else fails)
    quietVerdicts  good words that mean "nothing to tell Dave": the run's
                 session is archived (hidden from the dashboard's list,
                 still in `hermes sessions list --source oneshot`), so a
                 quiet night sends nothing; the log stays
    waitFor      lock files of other jobs to wait for (flock, up to
                 waitTimeout) before starting, so two jobs' builds never
                 overlap; the waiting client holds nothing. Still held
                 after waitTimeout: the run starts anyway and the prompt
                 says `BUSY=<lock>` (the skill then builds nothing heavy)
    after        units this one is ordered after (After=): when both are
                 queued at once (Persistent= timers after missed nights
                 fire together at boot), this one starts only once the
                 other oneshot finished, so it never checks a lock before
                 its holder took it
    sharedLock   a lock several jobs hold while they run (one of them at a
                 time); waited for like waitFor
    timeout      TimeoutStartSec
    maxTurns     --max-turns
    keepLogs     logs kept
    toolsets     the run's -t, from an allowlist (`allowedToolsets`
                 below: terminal, file, todo, delegation; `no_mcp` is
                 always added): no skills or memory toolset, and no
                 composite one that includes them (hermes-cli and the
                 other bundles), so a run steered by what it reads has no
                 skill or memory tool and no MCP server. Its terminal and
                 file tools can still write files as the job's user (the
                 tools run in the gateway's process, outside this unit):
                 no skill/memory tools, not "cannot persist"; the repo's
                 skills/ is refused by the security jobs' guard.
                 Delegated children inherit it. The -s skill is preloaded
                 at session creation and needs no skills toolset
                 (decisions-curate runs the same way, ./decisions.nix)

  Failures: the unit fails (journal, `systemctl --failed` in the guest;
  a stale recurring task once ../recurring-tasks/registry.nix lists it,
  read from som's host), OnFailure= files `decision notice "<name> failed, see <log>"`
  for the 09:00 brief, and the job registers itself in
  `infraSpace.agentJobs` (log dir, verdict tag, ok verdicts), from which
  the brief also reports a failed or crashed last run (./decisions.nix).

  The log is <logDir>/<UTC date>T<HHMM>Z.log (fileUmask); the verdict
  helper `<name>-verdict <log>` prints the last non-empty line (hermes'
  trailing `session_id:` aside) and exits 0 for an ok verdict.
*/
{
  config,
  lib,
  pkgs,
  inputs,
}:
{
  name,
  skill ? name,
  description,
  calendar,
  prompt,
  promptHook ? "",
  busyCheck ? null,
  verdictTag,
  okVerdicts,
  quietVerdicts ? [ ],
  waitFor ? [ ],
  sharedLock ? null,
  after ? [ ],
  waitTimeout ? 4 * 3600,
  timeout ? "16h",
  maxTurns ? 3000,
  keepLogs ? 60,
  # appended to the follower's continue message (./agent-job-follow.sh)
  resumeNote ? "",
  user ? "infra",
  group ? user,
  fileUmask ? "077",
  decisionCommand ? "/run/current-system/sw/bin/decision",
  toolsets ? [
    "terminal"
    "file"
    "todo"
    "delegation"
  ],
}:
let
  home = "/home/${user}";
  checkout = "${home}/hyperconfig";
  logDir = "${home}/${name}";
  promptFile = pkgs.writeText "${name}-prompt" prompt;
  tz = "TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok";
  # An allowlist, not a denylist: a composite toolset (hermes-cli,
  # hermes-cron, ...) includes skills and memory under another name.
  allowedToolsets = [
    "terminal"
    "file"
    "todo"
    "delegation"
  ];
  notAllowed = lib.subtractLists allowedToolsets toolsets;
  # no_mcp: hermes' sentinel that drops every configured MCP server
  # from the session (hermes_cli/tools_config.py _merge_mcp_servers)
  runToolsets = toolsets ++ [ "no_mcp" ];

  # OnFailure=: one line for the next morning brief, with the newest log
  failedNotice = pkgs.writeShellScript "${name}-failed-notice" ''
    log=$(ls -1t ${logDir}/*.log 2>/dev/null | head -n 1)
    ${decisionCommand} --by ${name} notice --source ${name} \
      "${name} failed on $(${tz} date '+%F %H:%M'), see ''${log:-${logDir}} in infra-space"
  '';

  verdict = pkgs.writeShellApplication {
    name = "${name}-verdict";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      [ $# = 1 ] || { echo "usage: ${name}-verdict <log>" >&2; exit 2; }
      last=$(grep -v -e '^[[:space:]]*$' -e '^session_id: [^ ]*$' "$1" | tail -n 1 || true)
      echo "''${last:-none}"
      case "$last" in
        ${lib.concatMapStringsSep " | " (v: lib.escapeShellArg "${verdictTag}: ${v}") okVerdicts}) exit 0 ;;
      esac
      exit 1
    '';
  };

  # The client is only a viewer of the turn (see ./nixpkgs-bump.nix's
  # header): it ends with "Gateway disconnected; turn outcome is unknown"
  # when the gateway drops its websocket (keepalive ping timeout under
  # load) or restarts, while the turn goes on, or is cut off by the
  # restart and never re-run. Then the unit follows the session itself
  # (./agent-job-follow.sh): it waits for the turn in the agent's
  # state.db, takes the report from the session, or resumes the session
  # (`hermes chat --resume`) when the turn was cut off. The unit stays
  # active all the while (its locks held).
  follow = pkgs.writeShellApplication {
    name = "${name}-follow";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.sqlite
      config.systemd.package
    ];
    # No errexit: a failed resume or discard must not end the follower
    # (it retries). The script's SQL holds the (validated) session id in
    # single quotes.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text =
      builtins.replaceStrings
        [
          "@hermesHome@"
          "@gatewayUnit@"
          "@maxResumes@"
          "@pollSec@"
          "@maxDbErrors@"
          "@verdict@"
          "@name@"
          "@skill@"
          "@verdictTag@"
          "@resumeNote@"
        ]
        [
          (inputs.hyperhermes.lib.lockedHermesHome user)
          "hermes-agent-${user}.service"
          "3"
          "30"
          "20"
          (lib.getExe verdict)
          name
          skill
          verdictTag
          resumeNote
        ]
        (builtins.readFile ./agent-job-follow.sh);
  };

  quietCase = lib.concatMapStringsSep " | " (v: lib.escapeShellArg "${verdictTag}: ${v}") quietVerdicts;

  waitLocks = lib.concatMapStrings (l: ''
    # wait for ${l}'s holder to finish; hold nothing
    if [ -e ${l} ] && ! flock -w ${toString waitTimeout} ${l} true; then
      echo "${name}: ${l} still held after ${toString waitTimeout}s, starting anyway (BUSY)" >&2
      busy="$busy ${l}"
    fi
  '') waitFor;

  run = pkgs.writeShellScript name ''
    set -uo pipefail
    umask ${fileUmask}
    mkdir -p ${logDir}
    # One client at a time, also when started by hand during a run.
    exec 9>${logDir}/.lock
    if ! flock -n 9; then
      echo "${name}: another run holds ${logDir}/.lock" >&2
      exit 1
    fi
    ${lib.optionalString (busyCheck != null) ''
      if why=$(${pkgs.writeShellScript "${name}-busy" busyCheck}); then
        echo "${name}: an earlier run is still going ($why): not starting" >&2
        prev=$(ls -1t ${logDir}/*.log 2>/dev/null | head -n 1)
        printf '%s\n%s\n' "an earlier run is still going: $why" "${verdictTag}: skipped" >${logDir}/$(date -u +%FT%H%MZ).log
        if [ -n "$prev" ] && grep -qx '${verdictTag}: skipped' "$prev"; then
          echo "${name}: skipped twice in a row: the earlier run looks stuck" >&2
          exit 1
        fi
        exit 0
      fi
    ''}
    busy=
    ${lib.concatMapStrings (u: ''
      # ${u}: when its timer is due within 20 min (missed nights: both
      # Persistent= timers fire at boot, each with its random delay), let
      # it start first; then the lock wait below sees it.
      t=${lib.removeSuffix ".service" u}.timer
      for _ in $(seq 60); do
        next=$(systemctl show -p NextElapseUSecRealtime --value "$t" 2>/dev/null)
        case "$next" in "" | n/a) break ;; esac
        due=$(date -d "$next" +%s 2>/dev/null) || break
        [ "$due" -le $(( $(date +%s) + 1200 )) ] || break
        sleep 30
      done
      # started, but maybe not yet holding its lock
      [ "$(systemctl show -p ActiveState --value ${u})" != activating ] || sleep 10
    '') after}
    ${waitLocks}
    ${lib.optionalString (sharedLock != null) ''
      exec 8>${sharedLock}
      if ! flock -w ${toString waitTimeout} 8; then
        echo "${name}: ${sharedLock} still held after ${toString waitTimeout}s, not starting" >&2
        exit 1
      fi
    ''}
    start=$(date -u +%FT%H:%M:%S)
    log=${logDir}/$(date -u +%FT%H%MZ).log
    echo "${name}: report in $log"
    # Logs of the last ${toString keepLogs} runs (before this one's).
    ls -1t ${logDir}/*.log 2>/dev/null | tail -n +${toString (keepLogs + 1)} | xargs -r rm -f
    query=${logDir}/last-prompt
    cat ${promptFile} >"$query"
    echo "LOCAL_DATE=$(${tz} date +%F) WEEKDAY=$(${tz} date +%u) LOG=$log" >>"$query"
    [ -z "$busy" ] || echo "BUSY=$busy" >>"$query"
    ${promptHook}
    # The agent's shim (core's agents.nix): HERMES_HOME and the gateway's
    # environment, as in Dave's sessions. --in is the job's own directory:
    # the session's cwd, by which the quiet-run archive below finds it.
    /run/current-system/sw/bin/hermes chat -Q -s ${skill} -t ${lib.concatStringsSep "," runToolsets} \
      --max-turns ${toString maxTurns} --in ${logDir} --query-file "$query" 2>&1 | tee "$log"
    rc=''${PIPESTATUS[0]}
    last=$(${lib.getExe verdict} "$log")
    ok=$?
    # No report at all: the client lost the turn (see `follow` above), or
    # the turn was cut off. Wait for the session, resume it if it was cut
    # off, and judge the report it ends with. A report with any verdict
    # is the run's verdict as it stands.
    if [ "$ok" != 0 ] || [ "$rc" != 0 ]; then
      sid=$(grep -o '^session_id: [A-Za-z0-9_-]*$' "$log" | tail -n 1 | cut -d' ' -f2 || true)
      case "$last" in ${lib.escapeShellArg "${verdictTag}: "}*) sid= ;; esac
      if [ -n "$sid" ]; then
        ${lib.getExe follow} "$sid" "$log"
        last=$(${lib.getExe verdict} "$log")
        ok=$?
        rc=resumed
      fi
    fi
    ${lib.optionalString (quietVerdicts != [ ]) ''
      # Nothing to tell Dave: hide this run's session from the dashboard's
      # list (archived, not deleted; the log keeps the report).
      case "$last" in
        ${quietCase})
          /run/current-system/sw/bin/hermes sessions archive --source oneshot --cwd ${logDir} \
            --after "$start" --include-open --yes >&2 || echo "${name}: archiving the quiet run's session failed" >&2
          ;;
      esac
    ''}
    [ "$ok" = 0 ] && { [ "$rc" = 0 ] || [ "$rc" = resumed ]; } && exit 0
    echo "${name}: failed (hermes exit $rc, last line: $last); see $log" >&2
    exit 1
  '';
in
{
  assertions = [
    {
      assertion = notAllowed == [ ];
      message = "agent-job ${name}: toolsets ${toString notAllowed} are not in the allowlist (${toString allowedToolsets}): an unattended run gets no skill or memory tools, composite toolsets included";
    }
  ];

  environment.systemPackages = [
    verdict
    follow
  ];

  infraSpace.agentJobs.${name} = {
    inherit logDir verdictTag okVerdicts;
  };

  systemd.services."${name}-failed-notice" = {
    description = "Morning-brief notice that ${name} failed";
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;
      ExecStart = failedNotice;
    };
    path = [
      pkgs.coreutils
    ];
  };

  systemd.services.${name} = {
    inherit description;
    # wants, not requires: a gateway restart must not restart (re-run) the
    # job. Nor does a switch start one.
    wants = [ "hermes-agent-${user}.service" ];
    after = [ "hermes-agent-${user}.service" ] ++ after;
    onFailure = [ "${name}-failed-notice.service" ];
    restartIfChanged = false;
    # The repository is cloned at boot once GitHub answers (./guest.nix).
    unitConfig.ConditionPathExists = checkout;
    path = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.util-linux # flock
      pkgs.systemd # the `after` units' timers
    ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = group;
      WorkingDirectory = home;
      ExecStart = run;
      TimeoutStartSec = timeout;
    };
  };

  systemd.timers.${name} = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = calendar;
      # A night som was down runs at the next boot.
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
