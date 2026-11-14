/*
  The fleet's decision registry: decisions only Dave can make, filed by
  every job and agent into one place, curated every morning, summed up
  in one short Telegram message, answered one at a time through
  /decisions. A guest module of ./hermes.nix, so it exists only where
  the agent runs (som).

  Pieces:
    - `decision` (./decisions/decision.py, tested by
      ./decisions/test_decision.py at build): the registry CLI. One JSON
      file per decision under ${store}/items, a log of every change
      (log.jsonl), flock-serialised. Jobs that cannot run it append JSON
      lines to inbox.jsonl (the contract path ${contract}/inbox.jsonl,
      a symlink into the store), which every command ingests first,
      bounded and validated (bad lines to inbox.rejected.jsonl). Writers
      append each line with one O_APPEND write (`>>`); ingest renames
      the file away before reading it, so a concurrent append lands in
      the next inbox instead of being truncated (best effort: a writer
      still holding the old file after ingest finished loses its line;
      re-ingest after a crash is deduplicated by title, notices by
      content). Caps: 200 pending decisions, log.jsonl
      rotated at 4 MiB. The store path is fixed at build (no --dir).
      notices.jsonl holds one-off lines for the next brief (a service
      the CVE watch took down).
    - decisions-curate.timer, 08:00 Asia/Bangkok: the agent with
      ./decisions/curate/SKILL.md, unattended (re-checks every open
      decision, obsoletes, merges, refreshes, re-ranks). A done run's
      session is archived: Dave sees nothing of it. Its bound is the
      prompt plus its toolsets: `-t terminal,file` (no skills, no
      delegation, no memory); terminal is still the agent's full shell
      with the fleet root key, so the prompt and skill are what keep it
      to the registry.
    - decisions-brief.timer, 09:00 Asia/Bangkok: a script, no agent.
      `decision brief` renders the open count, the top three titles
      (urgent first), the warning digest (space.decisions.digestCommand;
      a line when it could not be read), a line when last night's
      nixpkgs bump failed (nobody is paged for that) and the night's
      notices (six; the rest wait); nothing to say, nothing sent. It is
      sent by space.decisions.sendCommand. By default both go to edi
      (../telegram-send) over ssh with the dedicated `brief-ssh` key as
      the unprivileged `fleet-brief`, whose forced command allows only
      `send`, `send-nostamp` and `digest-json`: the bot token never
      leaves edi. That is defence in depth, not a trust boundary: the
      agent's fleet root key reaches edi anyway. A brief carrying the
      digest goes out with `send`, which stamps the day on edi; its own
      digest then skips 09:30. Without the digest (it failed, or none is
      configured) it is `send-nostamp`, so edi's 09:30 digest still
      brings the warnings. Exit codes: 3 = may have arrived (also ssh's
      255 and a timeout, which may hit after the message is out), 4 =
      edi's daily cap, 5 = sent but the notices not marked; none of them
      is retried (no double send).
    - skills `decisions` (./decisions/SKILL.md; hermes registers every
      skill as a slash command, so this is /decisions) and
      `decisions-curate`, both shipped by ./hermes.nix.

  The store is under infra's home (persistent: the host's
  /var/lib/infra-space/home); ${contract} is only the agreed path other
  jobs write to. Units: own timer + oneshot pairs in the shape of
  ./nixpkgs-bump.nix (wants/after the gateway, restartIfChanged off,
  explicit zone).

  Known gap, as for the bump: a failed unit in the guest pages nobody
  (no exporter in the container). A failed brief shows in the guest's
  journal and as no message; the warnings still come, from edi's 09:30
  fallback digest (unstamped day).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.space.decisions;
  user = "infra";
  home = "/home/${user}";
  store = "${home}/decisions";
  contract = "/var/lib/infra-space/decisions";
  curateDir = "${home}/decisions-curate";
  briefDir = "${home}/decisions-brief";

  cli = pkgs.writers.writePython3Bin "decision" { flakeIgnore = [ "E501" ]; } (
    lib.replaceStrings [ "@DIR@" ] [ contract ] (builtins.readFile ./decisions/decision.py)
  );
  decision = pkgs.runCommand "decision-tested" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${./decisions/decision.py} decision.py
    cp ${./decisions/test_decision.py} test_decision.py
    HOME=$TMPDIR python3 -m unittest -v test_decision
    ln -s ${cli} $out
  '';
  bin = "${decision}/bin/decision";

  verdictOf = pkgs.writeShellScript "decisions-curate-verdict" ''
    last=$(${pkgs.gnugrep}/bin/grep -v -e '^[[:space:]]*$' -e '^session_id: [^ ]*$' "$1" | ${pkgs.coreutils}/bin/tail -n 1 || true)
    echo "''${last:-none}"
    [ "$last" = "DECISIONS-CURATE: done" ]
  '';

  curatePrompt = pkgs.writeText "decisions-curate-prompt" ''
    This is the daily curation of the decision registry, started by
    decisions-curate.timer; nobody is watching. Follow the
    decisions-curate skill from step 1 to the report. Change nothing
    but the registry (the `decision` CLI): no pushes, no deploys, no
    messages to Dave. End with the skill's DECISIONS-CURATE line.
  '';

  curate = pkgs.writeShellScript "decisions-curate" ''
    set -uo pipefail
    umask 077
    mkdir -p ${curateDir}
    exec 9>${curateDir}/.lock
    if ! flock -n 9; then
      echo "decisions-curate: another run holds ${curateDir}/.lock" >&2
      exit 1
    fi
    start=$(date -u +%FT%H:%M:%S)
    log=${curateDir}/$(date -u +%FT%H%MZ).log
    echo "decisions-curate: report in $log"
    query=${curateDir}/last-prompt
    { cat ${curatePrompt}; echo "LOCAL_DATE=$(TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok date +%F)"; } >"$query"
    # Toolsets: the registry needs a shell and files; no skills (it must
    # not patch any), no delegation (no children to bound).
    /run/current-system/sw/bin/hermes chat -Q -s decisions-curate -t terminal,file --max-turns 400 \
      --in ${curateDir} --query-file "$query" 2>&1 | tee "$log"
    rc=''${PIPESTATUS[0]}
    ls -1t ${curateDir}/*.log | tail -n +31 | xargs -r rm -f
    last=$(${verdictOf} "$log")
    ok=$?
    if [ "$ok" = 0 ]; then
      # Nothing for Dave: hide the run's session from the dashboard's list
      # (archived, not deleted; the log keeps the report).
      /run/current-system/sw/bin/hermes sessions archive --source oneshot --cwd ${curateDir} \
        --after "$start" --include-open --yes >&2 || echo "decisions-curate: archiving the session failed" >&2
    fi
    [ "$ok" = 0 ] && [ "$rc" = 0 ] && exit 0
    echo "decisions-curate: failed (hermes exit $rc, last line: $last); see $log" >&2
    exit 1
  '';

  digestScript = lib.mapNullable (pkgs.writeShellScript "decisions-digest") cfg.digestCommand;
  # $1: send (stamps the day on edi) or send-nostamp
  sendScript = pkgs.writeShellScript "decisions-send" cfg.sendCommand;

  brief = pkgs.writeShellScript "decisions-brief" ''
    set -uo pipefail
    umask 077
    mkdir -p ${briefDir}
    exec 9>${briefDir}/.lock
    flock -n 9 || { echo "decisions-brief: another run holds the lock" >&2; exit 1; }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    digest=()
    ${lib.optionalString (digestScript != null) ''
      if timeout 180 ${digestScript} >"$tmp/digest.json" 2>"$tmp/digest.err"; then
        digest=(--digest-json "$tmp/digest.json")
      else
        echo "decisions-brief: the digest failed: $(head -c 400 "$tmp/digest.err")" >&2
        digest=(--digest-failed)
      fi
    ''}
    ${bin} --by morning-brief brief --json --bump-log-dir ${home}/nixpkgs-bump "''${digest[@]}" >"$tmp/brief.json" || exit 1
    jq -r .text "$tmp/brief.json" >"$tmp/text"
    if ! grep -q '[^[:space:]]' "$tmp/text"; then
      echo "decisions-brief: nothing to say, nothing sent"
      exit 0
    fi
    verb=$(jq -r .send "$tmp/brief.json")
    case $verb in
      send | send-nostamp) ;;
      *) echo "decisions-brief: unknown send verb '$verb'" >&2; exit 1 ;;
    esac
    timeout 180 ${sendScript} "$verb" <"$tmp/text"
    rc=$?
    case $rc in
      0) ;;
      3 | 124 | 255)
        # 3: edi's EXIT_MAYBE_SENT; 124 (timeout) and 255 (ssh's own
        # error, e.g. the link dropped mid-send) can come after the
        # message went out. No retry (Restart= would send twice);
        # the notices stay for tomorrow.
        echo "decisions-brief: send ended with $rc; it may have arrived" >&2
        exit 3 ;;
      4)
        echo "decisions-brief: edi's daily message cap is used up; not sent" >&2
        exit 4 ;;
      *)
        # surely not sent (edi's 1: Telegram refused or away): Restart=
        # retries. An unreachable edi is ssh's 255 above, not retried:
        # nothing is stamped then, so edi's 09:30 digest still goes out.
        echo "decisions-brief: sending failed (exit $rc)" >&2
        exit 1 ;;
    esac
    # Telegram accepted it: from here on never exit 1 (a retry would
    # send it again).
    mapfile -t sent < <(jq -r '.notices[]' "$tmp/brief.json")
    if [ "''${#sent[@]}" -gt 0 ]; then
      if ! ${bin} --by morning-brief notice --sent "''${sent[@]}"; then
        echo "decisions-brief: sent, but marking the notices failed: they repeat tomorrow" >&2
        exit 5
      fi
    fi
    { date -u +%FT%TZ; cat "$tmp/text"; } >${briefDir}/last-sent.txt || true
    echo "decisions-brief: sent ($(wc -l <"$tmp/text") lines)"
  '';

  # Only the dedicated key and user: -F /dev/null drops ssh_config's
  # `Host *.d` (User root, the fleet root key); host keys from the
  # system's known hosts (the fleet CA), no TOFU.
  briefSsh = lib.concatStringsSep " " [
    "ssh -F /dev/null"
    "-i /run/infra-space/secrets/brief-ssh -o IdentitiesOnly=yes"
    "-l fleet-brief"
    "-o BatchMode=yes -o ConnectTimeout=20"
    "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null"
    "-o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts"
    "--"
    cfg.ediHost
  ];

  unitBase = {
    wants = [ "hermes-agent-${user}.service" ];
    after = [ "hermes-agent-${user}.service" ];
    restartIfChanged = false;
  };
in
{
  options.space.decisions = {
    ediHost = lib.mkOption {
      type = lib.types.str;
      default = "edi.d";
      description = "Where fleet-brief's forced command runs (../telegram-send); another host in ./test.nix.";
    };
    digestCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${briefSsh} digest-json";
      defaultText = lib.literalMD "`digest-json` over the brief's ssh";
      description = ''
        Shell command printing the warning digest as JSON (fleet-alert-digest
        --json's list) for the morning brief; null leaves warnings out.
      '';
    };
    sendCommand = lib.mkOption {
      type = lib.types.str;
      default = "${briefSsh} \"$1\"";
      defaultText = lib.literalMD "`send` / `send-nostamp` (`$1`) over the brief's ssh";
      description = ''
        Shell command sending its stdin (the brief, plain text) to Dave;
        `$1` is `send` (the brief carries the digest: edi skips its own)
        or `send-nostamp` (it does not). Exit 3, 124 or 255 = it may have
        arrived, 4 = edi's daily cap (none retried).
      '';
    };
  };

  config = {
    environment.systemPackages = [ decision ];

    systemd.tmpfiles.rules = [
      "d ${store} 0700 ${user} ${user} -"
      "d ${store}/items 0700 ${user} ${user} -"
      "f ${store}/inbox.jsonl 0600 ${user} ${user} -"
      "d /var/lib/infra-space 0755 root root -"
      "L+ ${contract} - - - - ${store}"
    ];

    systemd.services.decisions-curate = unitBase // {
      description = "Daily curation of the decision registry by the infra agent";
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        WorkingDirectory = home;
        ExecStart = curate;
        TimeoutStartSec = "2h";
      };
    };
    systemd.timers.decisions-curate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # The guest runs on UTC: the zone is named.
        OnCalendar = "*-*-* 08:00:00 Asia/Bangkok";
        Persistent = true;
      };
    };

    systemd.services.decisions-brief = unitBase // {
      description = "Morning brief: open decisions and warnings, one Telegram message";
      wants = unitBase.wants ++ [ "network-online.target" ];
      after = unitBase.after ++ [ "network-online.target" ];
      path = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.openssh
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        WorkingDirectory = home;
        ExecStart = brief;
        TimeoutStartSec = "15min";
        # edi's send refused or Telegram away: try again, then give up
        # for the day (a failed unit; the notices stay for tomorrow).
        Restart = "on-failure";
        RestartSec = "10min";
        # 3 may have arrived, 4 edi's cap, 5 sent but notices unmarked:
        # a retry would (maybe) send the brief twice.
        RestartPreventExitStatus = [
          3
          4
          5
        ];
      };
      unitConfig.StartLimitBurst = 4;
      unitConfig.StartLimitIntervalSec = "2h";
    };
    systemd.timers.decisions-brief = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 09:00:00 Asia/Bangkok";
        # A morning som was down: sent at the next boot.
        Persistent = true;
      };
    };
  };
}
