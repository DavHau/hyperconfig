# SimpleX Chat CLI daemon — WebSocket bot API for hermes-agent.
#
# Runs the terminal client headless (`-p <port>`) as a dedicated system
# user. SimpleX needs no inbound connectivity: the daemon dials out to SMP
# relays; the phone connects via the bot's contact address.
#
# Fully declarative first-time setup: preStart creates the bot profile,
# a long-lived contact address, and enables daemon-side auto-accept.
# Pairing flow:
#   1. journalctl -u simplex-chat | grep 'simplex:/'   → open link on phone
#   2. contact auto-accepted by the daemon; send any message
#   3. bot replies with a pairing code → `hermes pairing approve simplex <CODE>`
#      (or pre-authorize via services.simplex-chat-daemon.allowedUsers)
#
# Hermes side: when services.hermes-agent is enabled, SIMPLEX_WS_URL is
# injected; the hermes container reaches the daemon via --network=host.
# Ad-hoc daemon commands while it runs: `simplex-cmd "/chats"` (WS API;
# never run `simplex-chat` one-shots against a live daemon's db).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.simplex-chat-daemon;
  package = import ./simplex-chat-package.nix { inherit pkgs; };

  # One-shot command against the running daemon's WebSocket API — the safe
  # way to poke the bot (accepting contact requests, listing chats) without
  # stopping the service: CLI one-shots on the db need the daemon down and
  # eat relay events. Example: simplex-cmd "/accept Dave_2"
  simplexCmd = pkgs.writers.writePython3Bin "simplex-cmd"
    {
      libraries = [ pkgs.python3Packages.websockets ];
      doCheck = false;
    } ''
    import asyncio
    import json
    import sys

    import websockets

    WS_URL = "ws://127.0.0.1:${toString cfg.port}"


    async def main():
        cmd = " ".join(sys.argv[1:])
        if not cmd:
            print('usage: simplex-cmd "/accept <name>" | "/chats" | ...')
            return 2
        async with websockets.connect(WS_URL) as ws:
            await ws.send(json.dumps({"corrId": "simplex-cmd", "cmd": cmd}))
            while True:
                raw = await asyncio.wait_for(ws.recv(), 15)
                msg = json.loads(raw)
                if msg.get("corrId") == "simplex-cmd":
                    print(json.dumps(msg.get("resp"), indent=2))
                    return 0


    sys.exit(asyncio.run(main()))
  '';
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
    environment.systemPackages = [
      package
      simplexCmd
    ];

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

      # First-boot bootstrap + idempotent settings, run against the db
      # BEFORE the daemon starts (single-writer): create the bot profile,
      # ensure a long-lived contact address exists, and let the DAEMON
      # auto-accept incoming requests (address-level /auto_accept — no
      # dependency on the hermes adapter's event handling).
      # The address link is printed on every start:
      #   journalctl -u simplex-chat | grep 'simplex:/'
      preStart = ''
        run_cmd() {
          ${package}/bin/simplex-chat \
            -d /var/lib/simplex-chat/simplex \
            --create-bot-display-name ${lib.escapeShellArg cfg.displayName} \
            --files-folder /var/lib/simplex-chat/files \
            -y -t 5 -e "$1" || true
        }
        run_cmd "/address"      # errors when one exists — harmless
        run_cmd "/auto_accept on"
        run_cmd "/show_address"
      '';

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
