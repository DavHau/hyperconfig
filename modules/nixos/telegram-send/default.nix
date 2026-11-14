/*
  edi's side of infra-space's morning brief (../infra-space/decisions.nix):
  Telegram messages from another machine's job without handing it the
  bot token, and the warning digest as JSON for the brief. The alert
  bot's token and chat id (grafana-telegram, ../monitoring-alerts.nix)
  stay here and are never printed.

  Access: an unprivileged system user `fleet-brief`, reached only with
  infra-space's dedicated `infra-space-brief` key (a shared clan var made
  on som, ../infra-space/default.nix; the private half is a credential
  of the guest that runs the brief), authorized as
  `restrict,command="fleet-brief-dispatch"`: ./dispatch.sh allows exactly
  `send`, `send-nostamp` (the message on stdin) and `digest-json` by
  SSH_ORIGINAL_COMMAND, each through one sudo rule to the root helper
  below, which runs the work as a DynamicUser transient unit with the
  digest's sandbox, capped at RuntimeMaxSec=120. Sends run one at a time
  (flock) as the stable dynamic user fleet-telegram-send, so the
  StateDirectory keeps its owner from run to run. Defence in depth, not a trust boundary: the same
  agent holds the fleet root key (../infra-space/fleet-access.nix) and
  can do anything here anyway; this only keeps the timer's path narrow
  and its mistakes small.

  ./send.py (fleet-telegram-send, tested with ./test_send.py against a
  stub Telegram at build): at most 20 messages a day, each cut to 4096
  UTF-16 units; exit 3 = may have arrived (no retry), 4 = daily cap.
  `send` stamps /var/lib/fleet-telegram-send/brief-sent with the day
  (Asia/Bangkok) once Telegram accepted the brief; `send-nostamp` is the
  same send without the stamp, for a brief that could not include the
  digest. Any other exit of the transient unit (killed at the runtime
  cap, systemd-run trouble) is reported as 3: it may have arrived.

  No digest lost: the brief carries the warnings, so edi's own digest
  (../monitoring-alert-digest) moves to 09:30 as a fallback and skips
  (ExecCondition) a day the brief was stamped; when the brief never
  came or came without the warnings (unstamped), the digest goes out as
  before, with its OnFailure page.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  telegram = config.clan.core.vars.generators.grafana-telegram.files;
  digest = config.hyper.monitoringAlertDigest;
  user = "fleet-brief";
  stateDir = "/var/lib/fleet-telegram-send";

  # The guest's public key, from the repo like ../infra-space/fleet-access.nix's.
  # Missing until som has generated the var: then nobody is authorized.
  keyFile =
    config.clan.core.settings.directory + "/vars/shared/infra-space-brief/id_ed25519.pub/value";
  hasKey = builtins.pathExists keyFile;

  send = pkgs.writers.writePython3Bin "fleet-telegram-send" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./send.py);
  tested = pkgs.runCommand "fleet-telegram-send-tested" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${./send.py} send.py
    cp ${./test_send.py} test_send.py
    cp ${./dispatch.sh} dispatch.sh
    python3 -m unittest -v test_send
    ln -s ${send} $out
  '';

  # systemd-run -p from a serviceConfig attrset (the digest's sandbox).
  props =
    attrs:
    lib.concatStringsSep " " (
      lib.mapAttrsToList (
        k: v:
        let
          s =
            if lib.isBool v then
              (if v then "yes" else "no")
            else if lib.isList v then
              lib.concatStringsSep " " v
            else
              toString v;
        in
        "-p ${lib.escapeShellArg "${k}=${s}"}"
      ) attrs
    );
  run = "${config.systemd.package}/bin/systemd-run --pipe --wait --quiet --collect -p DynamicUser=yes -p RuntimeMaxSec=120 ${props digest.hardening}";

  # One send at a time (the brief, a retry, root by hand), as one stable
  # dynamic user: StateDirectory is not re-chowned per run. Exit codes
  # other than send.py's own (0 1 3 4) mean the unit died or systemd-run
  # failed mid-way: maybe sent (3), never a retryable 1.
  sendCmd = pkgs.writeShellScript "fleet-telegram-send-run" ''
    exec 9>/run/lock/fleet-telegram-send.lock
    if ! ${pkgs.util-linux}/bin/flock -w 30 9; then
      echo "fleet-telegram-send: another send holds the lock; not sent" >&2
      exit 1
    fi
    ${run} -p User=fleet-telegram-send \
      -p StateDirectory=fleet-telegram-send -p StateDirectoryMode=0700 \
      -p LoadCredential=telegram-bot-token:${telegram.bot-token.path} \
      -p LoadCredential=telegram-chat-id:${telegram.chat-id.path} \
      ${tested}/bin/fleet-telegram-send "$@"
    rc=$?
    case $rc in
      0 | 1 | 3 | 4) exit $rc ;;
    esac
    echo "fleet-telegram-send: the send unit ended with $rc; it may have arrived" >&2
    exit 3
  '';
  digestCmd = pkgs.writeShellScript "fleet-alert-digest-json-run" ''
    exec ${run} -p ${lib.escapeShellArg "LoadCredential=${digest.tokenCredential}"} \
      -p After=grafana.service -p Wants=fleet-alert-digest-token.service -p After=fleet-alert-digest-token.service \
      ${digest.package}/bin/fleet-alert-digest --json
  '';

  # sudo's target: one fixed command per verb.
  rootHelper = pkgs.writeShellScript "fleet-brief-root" ''
    case "''${1-}" in
      send) exec ${sendCmd} --mark-brief ;;
      send-nostamp) exec ${sendCmd} ;;
      digest-json) exec ${digestCmd} ;;
    esac
    exit 2
  '';
  dispatch = pkgs.writeShellScript "fleet-brief-dispatch" ''
    export DISPATCH_SUDO=/run/wrappers/bin/sudo DISPATCH_ROOT=${rootHelper}
    exec ${pkgs.bash}/bin/bash ${./dispatch.sh}
  '';

  # For root on edi (by hand): the same runs.
  cliSend = pkgs.writeShellScriptBin "fleet-telegram-send" ''exec ${sendCmd} "$@"'';
  cliDigest = pkgs.writeShellScriptBin "fleet-alert-digest-json" "exec ${digestCmd}";

  skipIfBriefSent = pkgs.writeShellScript "fleet-alert-digest-skip-if-briefed" ''
    today=$(TZDIR=${pkgs.tzdata}/share/zoneinfo TZ=Asia/Bangkok ${pkgs.coreutils}/bin/date +%F)
    if [ "$(${pkgs.coreutils}/bin/cat ${stateDir}/brief-sent 2>/dev/null)" = "$today" ]; then
      echo "the morning brief carried today's warnings: digest skipped"
      exit 1
    fi
  '';
in
{
  config = lib.mkIf config.hyper.monitoringAlerts.telegram.enable {
    environment.systemPackages = [
      cliSend
      cliDigest
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      # sshd runs the forced command through the login shell
      useDefaultShell = true;
      openssh.authorizedKeys.keys = lib.optional hasKey ''restrict,command="${dispatch}" ${lib.fileContents keyFile}'';
    };
    users.groups.${user} = { };

    security.sudo.extraRules = [
      {
        users = [ user ];
        runAs = "root";
        commands =
          map
            (verb: {
              command = "${rootHelper} ${verb}";
              options = [ "NOPASSWD" ];
            })
            [
              "send"
              "send-nostamp"
              "digest-json"
            ];
      }
    ];

    warnings =
      lib.optional (!hasKey)
        "telegram-send: vars/shared/infra-space-brief is not generated yet; the morning brief cannot reach edi";

    # The fallback digest: after the brief, only on a day without one.
    hyper.monitoringAlertDigest = {
      onCalendar = "*-*-* 09:30:00 Asia/Bangkok";
      skipCondition = skipIfBriefSent;
    };
  };
}
