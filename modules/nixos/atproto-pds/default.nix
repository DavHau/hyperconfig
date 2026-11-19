# An atproto PDS (tranquil-pds, nixpkgs' services.tranquil-pds) for our own
# accounts: each account's identity is a did:web the PDS hosts itself
# (did:web:<handle>), so no PLC directory and no third party holds it.
# Dave signs in with it to his self-hosted Agave (docs/agave-self-hosted.md,
# H3/H4); som's instance is ../../../machines/som/atproto-pds.nix.
#
# The PDS listens on 127.0.0.1:`port` behind this host's nginx, which owns
# TLS (`tls`): https://<hostname>/ is the PDS, and every account's handle
# host https://<handle>/ serves only /.well-known/did.json and
# /.well-known/atproto-did from it (Host kept: tranquil answers a Host below
# `handleDomain` with that handle's DID document). Only root and nginx may
# dial the port (nft table atproto-pds): others on a shared host would
# otherwise reach it past nginx with an X-Forwarded-For of their choosing,
# the address tranquil rate-limits logins by. tranquil's cache (ripple) is
# bound to loopback and keyed with RIPPLE_CLUSTER_KEY, so no local user can
# feed it.
#
# Settings checked against tranquil 0.8.0's crates/tranquil-config: invite
# codes required (no open signup), PDS-hosted did:web on, no relay crawl
# requests (firehose.crawlers empty), no mail (MAIL_FROM_ADDRESS unset), and
# the verified-channel gate off: without mail no account could ever verify
# one and sign in; the gate is meant for open signups, which this PDS has
# none of.
#
# Accounts (`accounts.<name>`) are made by atproto-pds-accounts.service
# (./accounts.py, as root, after every start and every change of the
# password var): an account that does not exist yet is created through
# createAccount with the bootstrap invite code tranquil logs at a start
# with no users (so the first account must be one of these; it becomes the
# PDS's admin). Its password is the prompt-free clan var
# atproto-pds-<name>-password, random until its owner sets one:
#   clan-secret-prompt <machine> atproto-pds-<name>-password password
# and a deploy: the var's restartUnits rerun the unit, which writes a
# changed value to the account (the users row's bcrypt hash, as tranquil's
# admin updateAccountPassword does) and, as a changed var may be a leaked
# password's rotation, deletes the account's sessions, OAuth tokens,
# remembered OAuth devices, pending authorizations and app passwords
# (passkeys and TOTP stay: remove unknown ones in the PDS's UI), then restarts tranquil-pds (its in-memory session cache). It
# writes only when the var differs from the last value it applied (bcrypt
# marker in /var/lib/atproto-pds-accounts), so a password changed in the
# PDS's own UI stays until the var changes again. bcrypt reads a password's
# first 72 bytes only, as tranquil's does. psql gets the hash on stdin, not
# in argv (/proc/*/cmdline is readable by every uid).
#
# Secrets: atproto-pds-secrets (JWT_SECRET, DPOP_SECRET, MASTER_KEY,
# RIPPLE_CLUSTER_KEY). MASTER_KEY encrypts the accounts' signing keys:
# never regenerate it, or every account's did:web key is lost.
# State: postgres database tranquil-pds and /var/lib/tranquil-pds (blobs),
# both in the clan backup (clan.core.postgresql dumps the database; state
# atproto-pds).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.atprotoPds;
  inherit (lib) mkOption types;
  pds = config.services.tranquil-pds;
  upstream = "http://127.0.0.1:${toString cfg.port}";
  nginxUid = config.users.users.${config.services.nginx.user}.uid;
  stateDir = "/var/lib/atproto-pds-accounts";
  genOf = name: "atproto-pds-${name}-password";
  didOf = a: "did:web:${a.handle}";

  accountsScript = pkgs.writers.writePython3 "atproto-pds-accounts" {
    libraries = [ pkgs.python3Packages.bcrypt ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./accounts.py);
  accountsConfig = pkgs.writeText "atproto-pds-accounts.json" (
    builtins.toJSON {
      url = upstream;
      unit = "tranquil-pds.service";
      self = "atproto-pds-accounts.service";
      inherit stateDir;
      database = pds.user;
      dbUser = pds.user;
      accounts = lib.mapAttrsToList (name: a: {
        inherit name;
        inherit (a) handle email;
        did = didOf a;
      }) cfg.accounts;
    }
  );
in
{
  options.hyper.atprotoPds = {
    enable = lib.mkEnableOption "our own atproto PDS (tranquil-pds) with PDS-hosted did:web accounts";

    hostname = mkOption {
      type = types.str;
      example = "pds.example.com";
      description = "Public hostname of the PDS (its did:web documents' #atproto_pds endpoint is https://<hostname>).";
    };

    handleDomain = mkOption {
      type = types.str;
      example = "example.com";
      description = "Domain the accounts' handles sit directly below (tranquil's user_handle_domains).";
    };

    port = mkOption {
      type = types.port;
      default = 2583;
      description = "Loopback port of the PDS, behind nginx.";
    };

    tls = mkOption {
      type = types.attrsOf types.anything;
      default = {
        forceSSL = true;
        useACMEHost = cfg.hostname;
      };
      defaultText = lib.literalExpression "{ forceSSL = true; useACMEHost = cfg.hostname; }";
      description = "TLS part of the nginx virtual hosts (the PDS's and every handle's); the certificate is the machine's to provide.";
    };

    accounts = mkOption {
      default = { };
      description = "Accounts on the PDS, created and kept by atproto-pds-accounts.service.";
      type = types.attrsOf (
        types.submodule {
          options = {
            handle = mkOption {
              type = types.str;
              example = "alice.example.com";
              description = "Handle, directly below handleDomain; the account's DID is did:web:<handle>.";
            };
            email = mkOption {
              type = types.str;
              description = "The account's email (createAccount requires one; this PDS sends no mail).";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: a: {
      assertion =
        lib.hasSuffix ".${cfg.handleDomain}" a.handle
        && !lib.hasInfix "." (lib.removeSuffix ".${cfg.handleDomain}" a.handle);
      message = "hyper.atprotoPds.accounts.${name}.handle must be one label below ${cfg.handleDomain}.";
    }) cfg.accounts;

    services.tranquil-pds = {
      enable = true;
      database.createLocally = true;
      environmentFiles = [ config.clan.core.vars.generators.atproto-pds-secrets.files.env.path ];
      settings = {
        server = {
          host = "127.0.0.1";
          inherit (cfg) port hostname;
          user_handle_domains = [ cfg.handleDomain ];
          enable_pds_hosted_did_web = true;
          invite_code_required = true;
          disable_account_verification_gate = true;
          enable_caddy_on_demand_tls = false;
        };
        firehose.crawlers = [ ];
        cache.ripple.bind_addr = "127.0.0.1:0";
      };
    };
    systemd.services.tranquil-pds.environment.NO_COLOR = "1";

    clan.core.vars.generators = {
      atproto-pds-secrets = {
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          for k in JWT_SECRET DPOP_SECRET MASTER_KEY RIPPLE_CLUSTER_KEY; do
            printf '%s=%s\n' "$k" "$(openssl rand -hex 32)"
          done > "$out/env"
        '';
        files.env = {
          secret = true;
          restartUnits = [ "tranquil-pds.service" ];
        };
      };
    }
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair (genOf name) {
        runtimeInputs = [ pkgs.openssl ];
        # tranquil's createAccount wants a lower and an upper case letter
        # and a digit.
        script = ''
          printf 'Pds1-%s' "$(openssl rand -hex 24)" > "$out/password"
        '';
        files.password = {
          secret = true;
          restartUnits = [ "atproto-pds-accounts.service" ];
        };
      }
    ) cfg.accounts;

    systemd.services.atproto-pds-accounts = lib.mkIf (cfg.accounts != { }) {
      description = "Create the atproto PDS's accounts and apply their password vars";
      # and again after every start of the PDS
      wantedBy = [
        "multi-user.target"
        "tranquil-pds.service"
      ];
      requires = [ "tranquil-pds.service" ];
      after = [ "tranquil-pds.service" ];
      path = [
        config.services.postgresql.package
        config.systemd.package
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${accountsScript} ${accountsConfig}";
        StateDirectory = "atproto-pds-accounts";
        StateDirectoryMode = "0700";
        LoadCredential = lib.mapAttrsToList (
          name: _: "${name}:${config.clan.core.vars.generators.${genOf name}.files.password.path}"
        ) cfg.accounts;
        UMask = "0077";
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts = {
        ${cfg.hostname} = cfg.tls // {
          # tranquil's Prometheus endpoint (request paths and counts),
          # unauthenticated; nothing scrapes it.
          locations."= /metrics".return = "404";
          locations."/" = {
            proxyPass = upstream;
            proxyWebsockets = true;
            recommendedProxySettings = true;
            extraConfig = ''
              client_max_body_size 1g;
              proxy_buffering off;
              proxy_request_buffering off;
              proxy_read_timeout 1h;
              proxy_send_timeout 1h;
            '';
          };
        };
      }
      // lib.mapAttrs' (
        _: a:
        lib.nameValuePair a.handle (
          cfg.tls
          // {
            locations = {
              "= /.well-known/did.json" = {
                proxyPass = upstream;
                recommendedProxySettings = true;
              };
              "= /.well-known/atproto-did" = {
                proxyPass = upstream;
                recommendedProxySettings = true;
              };
              "/".return = "404";
            };
          }
        )
      ) cfg.accounts;
    };

    networking.nftables.enable = true;
    networking.nftables.tables.atproto-pds = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ip daddr 127.0.0.1 tcp dport ${toString cfg.port} meta skuid != { 0, ${toString nginxUid} } reject with tcp reset
        }
      '';
    };

    clan.core.postgresql = {
      enable = true;
      databases.${pds.user} = {
        # services.tranquil-pds creates it (database.createLocally).
        create.enable = false;
        service = "atproto-pds";
        restore.stopOnRestore = [
          "tranquil-pds.service"
          "atproto-pds-accounts.service"
        ];
      };
    };
    clan.core.state.atproto-pds.folders = [
      pds.dataDir
      stateDir
    ];
  };
}
