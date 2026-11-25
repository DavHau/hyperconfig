# The residential proxy gateway's mechanism (./gateway.py as a unit),
# without clan: ./default.nix wires it on som (vars, clients, Mullvad),
# ./test.nix exercises it against a fake provider.
#
#   - listens on 127.0.0.1:<port> only; who may connect is the nftables
#     table below: an output rule on lo by owner uid, so only
#     `clients` (users) reach the port, every other uid gets a reset;
#     each client uid holds at most `connectionsPerClient` connections at
#     once (fairness between agents, not a quota). No IPv6 listener;
#   - runs as its own static user, so ./default.nix can put it into
#     hyper.mullvadEgress (users, dns.services, tunnelOnly): it reaches the
#     provider only through the Mullvad tunnel, and nothing on loopback but
#     its own listener and the tunnel's DNS;
#   - the provider's username and password arrive as systemd credentials
#     (LoadCredential from root-owned files), readable only inside the unit;
#     no client ever sees them (clients send only a country/session hint as
#     their proxy username, ./gateway.py's header);
#   - no quotas: when the provider refuses (traffic used up), every
#     request answers 402 with a reason saying so.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.residentialProxy;
  clientUids = map (u: toString config.users.users.${u}.uid) cfg.clients;
in
{
  options.hyper.residentialProxy = {
    enable = lib.mkEnableOption "the loopback forward proxy to a residential proxy provider (./gateway.py)";
    user = lib.mkOption {
      type = lib.types.str;
      default = "residential-proxy";
      readOnly = true;
    };
    uid = lib.mkOption {
      type = lib.types.int;
      description = "Static uid (and gid) of the gateway's user, for uid-based egress rules.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8897;
    };
    url = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "http://127.0.0.1:${toString cfg.port}";
      description = "What clients put as their proxy.";
    };
    connectionsPerClient = lib.mkOption {
      type = lib.types.ints.positive;
      # One agent's uid carries its Camofox server, whose subagents and cron
      # runs each browse in a residential context of their own (hyperhermes
      # browser.limits.maxContexts, 10), at ~20 connections per loaded page.
      default = 160;
      description = "Concurrent connections one client uid may hold, so one agent cannot take every slot of the gateway (512, gateway.py MAX_CLIENTS).";
    };
    clients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users (static uids) allowed to connect to the gateway; every other uid is refused.";
    };
    defaultCountry = lib.mkOption {
      type = lib.types.strMatching "[A-Z]{2}";
      default = "SG";
    };
    upstream = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "rp.evomi-proxy.com";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 1001;
      };
      caFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "CA bundle to verify the provider's TLS endpoint with (tests); null: the system's.";
      };
    };
    userFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-owned file holding the provider's proxy username.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "Root-owned file holding the provider's proxy password.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = map (u: {
      assertion = config.users.users ? ${u} && config.users.users.${u}.uid != null;
      message = "hyper.residentialProxy.clients: '${u}' needs a static uid.";
    }) cfg.clients;

    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = cfg.user;
    };
    users.groups.${cfg.user}.gid = cfg.uid;

    systemd.services.residential-proxy = {
      description = "Loopback forward proxy to the residential proxy provider";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        LISTEN_HOST = "127.0.0.1";
        LISTEN_PORT = toString cfg.port;
        UPSTREAM_HOST = cfg.upstream.host;
        UPSTREAM_PORT = toString cfg.upstream.port;
        DEFAULT_COUNTRY = cfg.defaultCountry;
        ALLOWED_PORTS = "80 443";
      }
      // lib.optionalAttrs (cfg.upstream.caFile != null) { UPSTREAM_CA = "${cfg.upstream.caFile}"; };
      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        ExecStart = "${pkgs.python3}/bin/python3 ${./gateway.py}";
        LoadCredential = [
          "user:${cfg.userFile}"
          "password:${cfg.passwordFile}"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        # Nothing to keep: no state, no writes.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [ "@system-service" ];
        MemoryMax = "256M";
        TasksMax = 64;
        LimitNOFILE = 4096; # 512 tunnels x 2 sockets exceed the default soft 1024
        UMask = "0077";
      };
    };

    # Owner gate on the port: only the clients' uids may send to it over
    # lo (the gateway's replies leave from the port, not to it), each with
    # at most connectionsPerClient connections open; anything else gets a
    # reset.
    networking.nftables.enable = true;
    networking.nftables.tables.residential-proxy = {
      family = "inet";
      content = ''
        set perclient {
          typeof meta skuid
          flags dynamic
        }
        chain output {
          type filter hook output priority filter; policy accept;
          oifname "lo" tcp dport ${toString cfg.port} jump gate
        }
        chain gate {
          ${lib.optionalString (clientUids != [ ]) "meta skuid { ${lib.concatStringsSep ", " clientUids} } jump client"}
          counter reject with tcp reset
        }
        chain client {
          ct state new add @perclient { meta skuid ct count over ${toString cfg.connectionsPerClient} } counter reject with tcp reset
          accept
        }
      '';
    };
  };
}
