# SimpleX Chat CLI daemon — WebSocket bot API for hermes-agent.
#
# Runs the terminal client headless (`-p <port>`) as a dedicated system
# user. SimpleX needs no inbound connectivity: the daemon dials out to SMP
# relays; the phone pairs via an invitation link generated once with
# `sudo -u simplex simplex-chat -d /var/lib/simplex-chat/simplex -e "/connect"`
# (or `/address` for a long-lived bot address).
#
# The bot profile is created non-interactively on first start via
# --create-bot-display-name (no-op when the profile already exists).
#
# Hermes side: when services.hermes-agent is enabled, SIMPLEX_WS_URL is
# injected; the hermes container reaches the daemon via --network=host.
# Contacts are denied by default — approve with
# `hermes pairing approve simplex <CODE>` after messaging the bot, or set
# services.simplex-chat-daemon.allowedUsers.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.simplex-chat-daemon;
  package = import ./simplex-chat-package.nix { inherit pkgs; };
in
{
  options.services.simplex-chat-daemon = {
    enable = lib.mkEnableOption "SimpleX Chat bot daemon";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5225;
      description = "WebSocket port on 127.0.0.1 (hermes default).";
    };

    displayName = lib.mkOption {
      type = lib.types.str;
      default = "hermes";
      description = "Bot profile display name (first start only).";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SIMPLEX_ALLOWED_USERS for hermes: contactIds or display names.
        Empty list omits the variable — then only DM pairing grants access.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ package ];

    users.users.simplex = {
      isSystemUser = true;
      group = "simplex";
      home = "/var/lib/simplex-chat";
    };
    users.groups.simplex = { };

    systemd.services.simplex-chat = {
      description = "SimpleX Chat bot daemon";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        User = "simplex";
        Group = "simplex";
        StateDirectory = "simplex-chat";
        WorkingDirectory = "/var/lib/simplex-chat";
        ExecStart = lib.concatStringsSep " " [
          "${package}/bin/simplex-chat"
          "-p ${toString cfg.port}"
          "-d /var/lib/simplex-chat/simplex"
          "--create-bot-display-name ${lib.escapeShellArg cfg.displayName}"
          "--files-folder /var/lib/simplex-chat/files"
          "-y" # auto-confirm db migrations on package updates
        ];
        Restart = "always";
        RestartSec = 5;
        StandardInput = "null";

        # Hardening — outbound network + own state dir is all it needs.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ "/var/lib/simplex-chat" ];
      };
    };

    services.hermes-agent.environment = lib.mkIf config.services.hermes-agent.enable (
      {
        SIMPLEX_WS_URL = "ws://127.0.0.1:${toString cfg.port}";
      }
      // lib.optionalAttrs (cfg.allowedUsers != [ ]) {
        SIMPLEX_ALLOWED_USERS = lib.concatStringsSep "," cfg.allowedUsers;
      }
    );
  };
}
