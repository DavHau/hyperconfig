# Declarative porkbun DNS records:
#
#   hyper.porkbunRecords.records."<fqdn>".<type> = "<content>";
#   hyper.porkbunRecords.records."<fqdn>".<type>.command = [ prog args ];
#   hyper.porkbunRecords.records."<fqdn>".<type>.ipv6OnLink = { interface; suffix; };
#
# A command prints the content at sync time; ipv6OnLink is the common one,
# <the interface's current /64>::<suffix> (./ipv6-on-link.py), for addresses
# in a prefix the router hands out and may change. The zone is the fqdn's
# last two labels, as in tools/porkbun-dns.
#
# porkbun-records.service (./sync.sh) runs at boot once the network is up
# and then hourly, and only writes what differs: a second run makes no
# write call. It touches only records it declares, plus the records of a
# name/type it declared before (/var/lib/porkbun-records/managed.json) and
# no longer does, which it deletes. A record someone else made under a
# declared name/type is taken over (edited, and deleted once undeclared).
# Emptying `records` altogether removes the unit and leaves its records
# behind; drop names one deploy before that.
#
# Credentials: the shared `porkbun` clan var (as ../dyndns-porkbun.nix and
# the ACME DNS-01 certs), handed over with LoadCredential= and sent only in
# request bodies. The unit runs as a dynamic user: not a uid any
# hyper.mullvadEgress rule names, so it leaves through the host's normal
# uplink like the ACME units do. api.porkbun.com is an AWS load balancer
# whose addresses rotate, so the network allow-list is "the internet":
# private, LAN, mesh and link-local destinations are denied, loopback stays
# for the DNS stub.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.porkbunRecords;
  inherit (lib) mkOption types;

  stateDir = "/var/lib/porkbun-records";

  sync = pkgs.writeShellApplication {
    name = "porkbun-records-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gawk
      pkgs.jq
    ];
    text = builtins.readFile ./sync.sh;
  };

  ipv6OnLink = pkgs.writers.writePython3 "ipv6-on-link" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./ipv6-on-link.py);

  source = types.submodule {
    options = {
      command = mkOption {
        type = types.nullOr (types.nonEmptyListOf types.str);
        default = null;
        description = "Program and arguments printing the record's content at sync time.";
      };
      ipv6OnLink = mkOption {
        default = null;
        description = "<the interface's current /64>::<suffix>.";
        type = types.nullOr (
          types.submodule {
            options = {
              interface = mkOption { type = types.str; };
              suffix = mkOption {
                type = types.str;
                example = "::5107:4";
              };
              expectedPrefix = mkOption {
                type = types.nullOr types.str;
                default = null;
                example = "2405:9800:b901:94e3";
                description = "The /64 (first four groups) the host was configured for; a different one at runtime is logged as a warning.";
              };
            };
          }
        );
      };
    };
  };

  commandOf =
    s:
    if s.command != null then
      s.command
    else
      [
        "${ipv6OnLink}"
        s.ipv6OnLink.interface
        s.ipv6OnLink.suffix
      ]
      ++ lib.optional (s.ipv6OnLink.expectedPrefix != null) s.ipv6OnLink.expectedPrefix;

  flat = lib.concatLists (
    lib.mapAttrsToList (
      name: byType: lib.mapAttrsToList (type: value: { inherit name type value; }) byType
    ) cfg.records
  );

  configFile = pkgs.writeText "porkbun-records.json" (
    builtins.toJSON {
      inherit (cfg) apiBase ttl;
      stateFile = "${stateDir}/managed.json";
      records = map (
        r:
        {
          inherit (r) name type;
        }
        // (if lib.isString r.value then { content = r.value; } else { command = commandOf r.value; })
      ) flat;
    }
  );
in
{
  options.hyper.porkbunRecords = {
    records = mkOption {
      type = types.attrsOf (types.attrsOf (types.either types.str source));
      default = { };
      example = {
        "host.example.com".A = "192.0.2.1";
      };
      description = "fqdn -> record type -> content, or a source computing it at sync time.";
    };
    ttl = mkOption {
      type = types.ints.positive;
      default = 600;
      description = "TTL of records this module creates or edits.";
    };
    apiBase = mkOption {
      type = types.str;
      default = "https://api.porkbun.com/api/json/v3";
      description = "porkbun API endpoint (a stub in the VM tests).";
    };
    apiKeyFile = mkOption {
      type = types.str;
      default = config.clan.core.vars.generators.porkbun.files.apikey.path;
      defaultText = "the shared porkbun clan var";
    };
    secretKeyFile = mkOption {
      type = types.str;
      default = config.clan.core.vars.generators.porkbun.files.secretkey.path;
      defaultText = "the shared porkbun clan var";
    };
    package = mkOption {
      type = types.package;
      readOnly = true;
      default = sync;
      description = "The sync script (porkbun-records-sync [--dry-run] <config.json>), for dry runs.";
    };
    configFile = mkOption {
      type = types.path;
      readOnly = true;
      default = configFile;
      description = "What the unit syncs, for `porkbun-records-sync --dry-run` elsewhere.";
    };
  };

  config = lib.mkIf (cfg.records != { }) {
    assertions = map (r: {
      assertion = lib.isString r.value || (r.value.command == null) != (r.value.ipv6OnLink == null);
      message = "hyper.porkbunRecords.records.\"${r.name}\".${r.type}: set exactly one of command and ipv6OnLink";
    }) flat;

    # Shared var, same definition as ../dyndns-porkbun.nix.
    clan.core.vars.generators.porkbun = {
      share = true;
      prompts.apikey.type = "hidden";
      prompts.apikey.persist = true;
      prompts.secretkey.type = "hidden";
      prompts.secretkey.persist = true;
    };

    systemd.services.porkbun-records = {
      description = "Sync declared porkbun DNS records";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${sync}/bin/porkbun-records-sync ${configFile}";
        LoadCredential = [
          "apikey:${cfg.apiKeyFile}"
          "secretkey:${cfg.secretKeyFile}"
        ];
        DynamicUser = true;
        StateDirectory = "porkbun-records";
        UMask = "0077";
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectHostname = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        # ipv6OnLink reads /proc/net/if_inet6, no netlink needed.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        IPAddressDeny = [
          "link-local"
          "multicast"
          "10.0.0.0/8"
          "100.64.0.0/10"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "fc00::/7"
          # yggdrasil, retiolum (as in ../mullvad-egress/egress.nix)
          "200::/7"
          "42::/16"
        ];
      };
    };
    systemd.timers.porkbun-records = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnCalendar = "hourly";
        RandomizedDelaySec = "5min";
      };
    };
  };
}
