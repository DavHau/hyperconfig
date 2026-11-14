# Daily digest of the fleet's warnings, one Telegram message at 09:00
# (+07, Asia/Bangkok). ../monitoring-alerts.nix pages only criticals in
# real time and mutes severity=warning; this timer reads Grafana's alert
# state (what fires now) and state history (what fired and resolved in
# the last 24 h) and sends them in one message through the same bot and
# chat (grafana-telegram vars). No warnings, no message.
#
# ./digest.py is also a CLI for other reports (a morning brief):
#   fleet-alert-digest --json      entries as JSON, sends nothing
#   fleet-alert-digest --dry-run   the message it would send
# Both need the Grafana token credential; on edi:
#   systemd-run --pipe --wait -p DynamicUser=yes \
#     -p LoadCredential=grafana-token:/var/lib/fleet-alert-digest-token/grafana-token \
#     fleet-alert-digest --dry-run
# or `systemctl start fleet-alert-digest` to send now.
#
# Grafana is read over loopback with a Viewer service-account token.
# Grafana can't provision service accounts from files, so the root
# oneshot fleet-alert-digest-token (./provision_token.py) creates the
# account through the API with the grafana-admin fallback account,
# idempotently (a Viewer whose token still works is kept; a changed role
# is set back and the token rotated), and keeps the token in a root-only
# state file the digest gets as a systemd credential.
# Neither token is ever printed.
#
# For other modules (../telegram-send: the morning brief's edi side):
# hyper.monitoringAlertDigest.{package,hardening,tokenCredential} (read
# only: the tested binary, the units' sandbox, the Viewer token as a
# LoadCredential= value) and .onCalendar / .skipCondition (the brief
# moves the timer behind itself and skips a day it already reported).
#
# A failed digest (after its retries) or token run pages: OnFailure=
# starts fleet-alert-digest-failed, which sends one short "alert digest
# failed" naming the unit ($MONITOR_UNIT) through the same bot. That
# unit has no OnFailure= or Restart= of its own, so a dead Telegram
# can't loop; it stays a failed unit. Once the message is out, the
# digest never retries (no double send): a 5xx/timeout after sending
# exits 3, which RestartPreventExitStatus= keeps from retrying, and the
# failure unit says the digest may not have arrived (see ./digest.py).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  digest = pkgs.writers.writePython3Bin "fleet-alert-digest" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./digest.py);

  tested = pkgs.runCommand "fleet-alert-digest-tested" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    cp ${./digest.py} digest.py
    cp ${./test_digest.py} test_digest.py
    cp ${./provision_token.py} provision_token.py
    cp ${./test_provision_token.py} test_provision_token.py
    cp ${./default.nix} default.nix
    python3 -m unittest -v test_digest test_provision_token
    ln -s ${digest} $out
  '';

  provisionToken = pkgs.writers.writePython3 "fleet-alert-digest-token" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./provision_token.py);

  admin = config.clan.core.vars.generators.grafana-admin.files;
  telegram = config.clan.core.vars.generators.grafana-telegram.files;
  tokenDir = "/var/lib/fleet-alert-digest-token";

  telegramCreds = [
    "telegram-bot-token:${telegram.bot-token.path}"
    "telegram-chat-id:${telegram.chat-id.path}"
  ];
  hardening = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallFilter = [ "@system-service" ];
  };
in
{
  options.hyper.monitoringAlertDigest = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = tested;
      description = "fleet-alert-digest, its unit tests run at build.";
    };
    hardening = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      default = hardening;
      description = "The sandbox of the digest's units (serviceConfig).";
    };
    tokenCredential = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "grafana-token:${tokenDir}/grafana-token";
      description = "The Grafana Viewer token as a LoadCredential= value.";
    };
    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 09:00:00 Asia/Bangkok";
      description = "When the digest is sent (edi runs in UTC: name the zone).";
    };
    skipCondition = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "A root ExecCondition= of the digest: exit 1 skips that run (no message, no failure).";
    };
  };

  config = lib.mkIf config.hyper.monitoringAlerts.telegram.enable {
    environment.systemPackages = [ tested ];

    systemd.services.fleet-alert-digest-token = {
      description = "Grafana Viewer token for the alert digest";
      # Runs before each digest (its Requires=) and once at boot, so a
      # broken token shows early; a switch doesn't restart a oneshot
      # without RemainAfterExit, so not on every switch.
      wantedBy = [ "multi-user.target" ];
      after = [ "grafana.service" ];
      wants = [ "grafana.service" ];
      onFailure = [ "fleet-alert-digest-failed.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${provisionToken} ${tokenDir}/grafana-token";
        # Runs as root (reads the admin credential); only its state dir
        # is writable and nobody else can read the token in it.
        StateDirectory = "fleet-alert-digest-token";
        StateDirectoryMode = "0700";
        UMask = "0077";
        LoadCredential = [
          "grafana-admin-username:${admin.username.path}"
          "grafana-admin-password:${admin.password.path}"
        ];
      };
    };

    systemd.services.fleet-alert-digest = {
      description = "Daily Telegram digest of the fleet's warnings";
      after = [
        "grafana.service"
        "fleet-alert-digest-token.service"
        "network-online.target"
      ];
      requires = [ "fleet-alert-digest-token.service" ];
      wants = [ "network-online.target" ];
      # Only once the retries below are used up: RestartMode=direct skips
      # OnFailure= between auto-restarts (normal mode triggers it on each
      # one; tried on edi's systemd 262).
      onFailure = [ "fleet-alert-digest-failed.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${tested}/bin/fleet-alert-digest";
        DynamicUser = true;
        LoadCredential = [ "grafana-token:${tokenDir}/grafana-token" ] ++ telegramCreds;
        # "+": as root, outside the sandbox (reads another unit's state)
        ExecCondition = lib.mkIf (
          config.hyper.monitoringAlertDigest.skipCondition != null
        ) "+${config.hyper.monitoringAlertDigest.skipCondition}";
        # Retry a Grafana restart or a Telegram hiccup from before the
        # request went out, then page through fleet-alert-digest-failed.
        Restart = "on-failure";
        RestartMode = "direct";
        RestartSec = "5min";
        # 3 = sent, but Telegram answered 5xx or not at all: fail (pages
        # "may not have arrived") without a retry that would send twice.
        RestartPreventExitStatus = [ 3 ];
      };
      unitConfig.StartLimitBurst = 4;
      unitConfig.StartLimitIntervalSec = "1h";
    };

    systemd.services.fleet-alert-digest-failed = {
      description = "Telegram notice that the alert digest failed";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${tested}/bin/fleet-alert-digest --notify-failure";
        DynamicUser = true;
        LoadCredential = telegramCreds;
      };
    };

    systemd.timers.fleet-alert-digest = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = config.hyper.monitoringAlertDigest.onCalendar;
        # A digest missed while edi was down is sent when it is back.
        Persistent = true;
      };
    };
  };
}
