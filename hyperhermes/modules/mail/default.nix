# Receive-only email for the agents (services.hyperhermes.agents):
# <agent>@<mail.domain>, Stalwart as MX, mailgate as sanitizer, quarantine,
# allowlist and alias registry. Public deployments only (asserted): the MX
# takes mail from the internet, and the owner page (./owner-page.nix) sits
# behind the sso front door. Secrets are runtime paths; nixosModules.clan
# fills them from the generators `mailgate`, `mailgate-imap-<agent>` and
# `mailgate-oauth2-proxy`.
#
# Mail path:
#
#   internet --25/tcp, IPv4--> Stalwart (MX; rate limits per IP and per IP
#     and sender domain, a queue quota, a recipient cap)
#     MAIL: Stalwart asks mailgate's hook (127.0.0.1:226), which refuses
#           MAIL FROM and EHLO values outside a plain grammar.
#     RCPT: the hook again; unknown local parts and revoked aliases get 550.
#     DATA: Stalwart checks SPF/DKIM/DMARC, writes its Authentication-Results
#           on top, and relays the message over LMTP (127.0.0.1:24) to
#           mailgate. Its only queue route; it never delivers anywhere else.
#   mailgate (own system user): allowlisted sender with DMARC pass and a DKIM
#     signature by exactly the From domain -> a sanitized plain-text copy
#     APPENDed to the agent's INBOX in Stalwart (IMAP master login); anything
#     else -> quarantine (capped per agent and per source) in its own 0700
#     state directory. Originals stay there, once per content; attachments
#     are fetched one by one. Every parse runs in a killable worker
#     (./analyze.py).
#   agent: reads its INBOX with `mailgate inbox` / `mailgate read <id>`
#     (rendered from the original here) and everything else through
#     /run/mailgate/agent.sock, where the peer uid picks the mailbox. The
#     IMAP copy on 127.0.0.1:143 holds the same sanitized text; the agent
#     reads it with `himalaya`, built with the IMAP backend only (no SMTP
#     or other transport compiled in), as its own IMAP account: the
#     password is the agent's alone (mailgate-imap-passwords copies it to
#     /run/mailgate-imap/<agent>/password, 0400 the agent).
#
# Why the agent cannot reach the raw mail: its IMAP account only ever holds
# the sanitized copies (Stalwart delivers nothing itself), the originals and
# the quarantine are mailgate's 0700 files, Stalwart's store is 0700
# stalwart, and the only credential that opens other accounts (the IMAP
# master secret) is a credential of mailgate and Stalwart alone.
#
# Ports below 1024 on loopback, so no agent can bind one while its owner is
# down, and owner-match gates (mailgate-firewall, IPv4 and IPv6) on top:
# only Stalwart and root dial LMTP and the hook, only root dials the MX from
# this host (local users cannot inject mail; agents cannot reach it through
# the forwarded public address either, `mxAddresses`), only the agents,
# mailgate and root dial IMAP, and nobody but root reaches 587 (submission,
# which nothing serves; should anything ever listen there, agents still
# cannot send through it). Stalwart may open no connection off this host
# except DNS; mailgate only DNS and the summariser's port.
#
# DNS: the mail domain is usually not exposure.domain (agent-controlled),
# and these records are not in exposure.dnsRecords; the deployment's zone
# holds them. Nothing is ever sent from the domain, so SPF and DMARC say so:
#   <hostname>             A     <public IPv4 of the MX>   (no AAAA)
#   <domain>               MX    10 <hostname>
#   <domain>               TXT   "v=spf1 -all"
#   <hostname>             TXT   "v=spf1 -all"
#   _dmarc.<domain>        TXT   "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"
#   *._domainkey.<domain>  TXT   "v=DKIM1; p="   (no key is valid)
# and a PTR for the address to <hostname> if its provider allows one
# (senders may score a missing or mismatching PTR).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.mail;
  exposure = config.services.hyperhermes.exposure;
  # The sso module is optional; the owner page needs its front door.
  sso = config.services.hyperhermes.sso or null;
  frontDoorHost = if sso == null || !sso.enable then null else sso.frontDoor.host;
  # Agent name -> its mailbox (agents.<name>.mail), for the agents that
  # have one.
  mailboxes = lib.mapAttrs (_: a: a.mail) (
    lib.filterAttrs (_: a: a.mail.enable) config.services.hyperhermes.agents
  );
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);
  lmtpPort = 24;
  hookPort = 226;
  imapPort = 143;
  # Submission. Nothing listens and the firewall refuses everyone but root.
  closedSmtpPort = 587;
  stalwartUser = config.services.stalwart.user;
  credDir = "/run/credentials/stalwart.service";
  # Each agent's own copy of its IMAP password (mailgate-imap-passwords).
  passwordDir = "/run/mailgate-imap";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./mailgate.py
      ./analyze.py
      ./sanitize.py
      ./client.py
    ];
  };
  python = pkgs.python3.withPackages (ps: [ ps.aiohttp ]);
  package = pkgs.symlinkJoin {
    name = "mailgate";
    paths = [
      (pkgs.writeShellScriptBin "mailgate" ''exec ${pkgs.python3}/bin/python3 ${src}/client.py "$@"'')
      (pkgs.writeShellScriptBin "mailgate-admin" ''exec ${pkgs.python3}/bin/python3 ${src}/client.py --admin "$@"'')
    ];
  };

  # The read-only IMAP client: himalaya with the IMAP backend alone, so no
  # build of it can submit mail anywhere (no SMTP, sendmail, JMAP, Gmail or
  # Graph transport compiled in). `himalaya` picks the caller's account by
  # unix name: the agent's own mailbox, logged in with its own password.
  himalayaPackage = pkgs.himalaya.override {
    buildNoDefaultFeatures = true;
    buildFeatures = [
      "imap"
      "rustls-ring"
    ];
  };
  toml = pkgs.formats.toml { };
  himalayaConfigFor =
    name:
    toml.generate "himalaya-${name}.toml" {
      accounts.${name} = {
        default = true;
        email = "${name}@${cfg.domain}";
        # Plain IMAP on loopback, as Stalwart listens.
        imap = {
          server = "imap://127.0.0.1:${toString imapPort}";
          starttls = false;
          sasl.plain = {
            username = name;
            password.command = [
              "${pkgs.coreutils}/bin/cat"
              "${passwordDir}/${name}/password"
            ];
          };
        };
        mailbox.alias.inbox = "INBOX";
      };
    };
  himalaya = pkgs.writeShellScriptBin "himalaya" ''
    case "$(${pkgs.coreutils}/bin/id -un)" in
    ${lib.concatMapStrings (name: ''
      ${name}) HIMALAYA_CONFIG=${himalayaConfigFor name} ;;
    '') (lib.attrNames mailboxes)}
      *)
        echo "himalaya: $(${pkgs.coreutils}/bin/id -un) has no agent mailbox on this host" >&2
        exit 1
        ;;
    esac
    export HIMALAYA_CONFIG
    exec ${himalayaPackage}/bin/himalaya "$@"
  '';

  ownerOrigin = if cfg.ownerPage.host == null then null else "https://${cfg.ownerPage.host}";
  configFile = pkgs.writeText "mailgate.json" (
    builtins.toJSON {
      inherit (cfg) domain hostname limits;
      stateDir = "/var/lib/mailgate";
      imap = {
        host = "127.0.0.1";
        port = imapPort;
        master = "mailgate";
      };
      lmtpUser = "stalwart";
      hookUser = "stalwart";
      agents = lib.mapAttrs (_: a: {
        inherit (a) owner;
        allowlist = map lib.toLower a.allowlist;
      }) mailboxes;
      ownerUrl = if ownerOrigin == null then null else "${ownerOrigin}/";
      inherit ownerOrigin;
      summarizer =
        if cfg.summarizer.enable then
          {
            inherit (cfg.summarizer) url model;
          }
        else
          null;
      psl = "${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat";
    }
  );

  sockets = {
    lmtp = {
      listen = "127.0.0.1:${toString lmtpPort}";
      extra = { };
    };
    hook = {
      listen = "127.0.0.1:${toString hookPort}";
      extra = { };
    };
    # Anyone may connect; the daemon answers only uids that own a mailbox.
    agent = {
      listen = "/run/mailgate/agent.sock";
      extra.SocketMode = "0666";
    };
    # nginx alone (the owner page behind its own login).
    owner = {
      listen = "/run/mailgate/owner.sock";
      extra = {
        SocketMode = "0660";
        SocketGroup = if config.services.nginx.enable then config.services.nginx.group else "root";
      };
    };
    admin = {
      listen = "/run/mailgate/admin.sock";
      extra.SocketMode = "0600";
    };
  };

  # Owner-match gates on loopback ports, for IPv4 and IPv6 alike (nothing
  # listens on ::1 today; the v6 gates keep it that way should a listener
  # ever gain [::]); `gate <port> <uid>...` lets those uids and root through
  # and resets everyone else.
  gates = ''
    gate() {
      port=$1; shift
      for ipt in iptables ip6tables; do
        for u in "$@" 0; do
          $ipt -w -A mailgate-lo -p tcp --dport "$port" -m owner --uid-owner "$u" -j RETURN
        done
        $ipt -w -A mailgate-lo -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
      done
    }
    gate ${toString lmtpPort} ${stalwartUser}
    gate ${toString hookPort} ${stalwartUser}
    gate 25
    gate ${toString closedSmtpPort}
    gate ${toString imapPort} mailgate ${lib.concatStringsSep " " (lib.attrNames mailboxes)}
  '';

  # When the MX's public address belongs to another host that forwards it
  # here, this host's own traffic to it leaves over the uplink and comes
  # back like any internet sender's, past the loopback gate on 25.
  mxHairpin = lib.concatMapStrings (
    addr:
    lib.concatMapStrings (agent: ''
      iptables -w -A mailgate-mx -d ${addr} -p tcp --dport 25 -m owner --uid-owner ${agent} -j REJECT --reject-with tcp-reset
    '') (lib.attrNames mailboxes)
  ) cfg.mxAddresses;

  skill = import ../../lib/agent-skill.nix pkgs {
    name = "mailgate";
    src = pkgs.writeTextDir "SKILL.md" (
      builtins.replaceStrings
        [ "@DOMAIN@" "@INBOX_DAYS@" ]
        [ cfg.domain (toString cfg.limits.inboxDays) ]
        (builtins.readFile ./skill/SKILL.md)
    );
  };
in
{
  imports = [ ./owner-page.nix ];

  options.services.hyperhermes = with lib; {
    mail = {
      enable = mkEnableOption "receive-only mailboxes for the agents (public exposure only)";

      domain = mkOption {
        type = types.str;
        example = "agents.example.com";
        description = "Mail domain: every agent with a mailbox receives at <agent>@<domain>.";
      };
      hostname = mkOption {
        type = types.str;
        default = "mail.${cfg.domain}";
        defaultText = literalExpression ''"mail.''${domain}"'';
        description = "The MX host name: SMTP greeting, TLS certificate, authserv-id of Authentication-Results.";
      };
      smtpInterfaces = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Interfaces where 25/tcp is opened; the listener itself is IPv4 only.";
      };

      secrets = lib.genAttrs [ "master" "hook" "lmtp" "csrf" ] (
        n:
        mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Runtime path of the root-only internal shared secret `${n}` (a random string).";
        }
      );

      acme = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Obtain the MX certificate for `hostname` by DNS-01 with
          exposure.acme's provider, credentials and resolver (port 80 of the
          MX name is nobody's), and use it as `tls`.
        '';
      };
      tls = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              certFile = mkOption { type = types.str; };
              keyFile = mkOption { type = types.str; };
            };
          }
        );
        default =
          if cfg.acme then
            {
              certFile = "/var/lib/acme/${cfg.hostname}/fullchain.pem";
              keyFile = "/var/lib/acme/${cfg.hostname}/key.pem";
            }
          else
            null;
        defaultText = literalMD "the ACME certificate of `hostname` when `acme` is on, else null";
        description = "Certificate for STARTTLS on the MX; null offers no TLS.";
      };

      summarizer = {
        enable = mkEnableOption "summaries of quarantined mail by a tool-less model";
        url = mkOption {
          type = types.str;
          example = "https://inference.example.com/v1";
          description = "OpenAI-compatible base URL.";
        };
        model = mkOption {
          type = types.str;
          description = "Model id at that endpoint.";
        };
        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Runtime path of the bearer token (root-readable).";
        };
        egressPort = mkOption {
          type = types.port;
          default = 443;
          description = "The only TCP port mailgate may dial off this host.";
        };
      };

      ownerPage = {
        host = mkOption {
          type = types.nullOr types.str;
          default = if frontDoorHost == null then null else "mailgate.${frontDoorHost}";
          defaultText = literalExpression ''"mailgate.''${sso.frontDoor.host}", or null without a front door'';
          description = ''
            Host of the owner page (./owner-page.nix), under the front door's
            certificate; the CSRF origin check and the links in request
            answers use it. Null: no owner page (root decides with
            mailgate-admin).
          '';
        };
        cookieSecretFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Runtime path of the owner page's oauth2-proxy cookie secret: 16, 24 or 32 bytes, raw or in URL-safe base64.";
        };
      };

      mxAddresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "192.0.2.1" ];
        description = ''
          Public IPv4 addresses of the MX when they are not this host's own
          (a forwarded address). Agents may not dial port 25 there: the
          connection would hairpin back in as an internet sender and skip
          the loopback gate.
        '';
      };

      limits =
        let
          limit =
            default: description:
            mkOption {
              type = types.ints.positive;
              inherit default description;
            };
        in
        {
          messageBytes = limit 10485760 "Largest message Stalwart accepts; mailgate keeps 1 MiB of headroom for Stalwart's own headers.";
          attachmentBytes = limit 10485760 "Largest attachment an agent may fetch.";
          maxRecipients = limit 10 "Recipients per SMTP transaction.";
          inboundPerIpHour = limit 60 "Messages per remote IP and hour (Stalwart rate limit).";
          inboundPerSenderDomainHour = limit 30 "Messages per remote IP and MAIL FROM domain and hour (Stalwart rate limit).";
          queueBytes = limit 268435456 "Bytes Stalwart's queue may hold before it tempfails new mail.";
          queueMessages = limit 500 "Messages Stalwart's queue may hold before it tempfails new mail.";
          quarantineBytes = limit 104857600 "Per agent: quarantined bytes kept (each original once).";
          quarantineMessages = limit 300 "Per agent: quarantined messages kept.";
          quarantineSourceBytes = limit 20971520 "Per agent and source (an aligned sender's organizational domain, else the sending /24 or /64): quarantined bytes kept; beyond it the source only pushes out its own entries.";
          quarantineSourceMessages = limit 50 "Per agent and source: quarantined messages kept.";
          quarantineKeepBytes = limit 1048576 "A quarantined message bigger than this keeps only its first bytes and never moves to the INBOX.";
          quarantineDays = limit 14 "Days a quarantined message is kept.";
          inboxDays = limit 90 "Days an INBOX original (for attachments) is kept.";
          summaryQueue = limit 100 "Quarantined messages waiting for a summary; more are marked queue-full.";
          workerSeconds = limit 60 "Hard timeout of one parse of a message (analyze.py), after which it is killed.";
          workerMemoryBytes = limit 671088640 "Address-space limit of one parse.";
          agentConnections = limit 4 "Per agent: open connections to agent.sock; more are refused at once.";
          pendingRequests = limit 5 "Per agent: open allowlist requests.";
          requestsPerDay = limit 10 "Per agent: allowlist requests per day.";
          activeAliases = limit 200 "Per agent: live aliases.";
          aliasesPerDay = limit 20 "Per agent: aliases created per day.";
          summariesPerAgentDay = limit 50 "Per agent: summaries per day.";
          summariesPerDay = limit 300 "Summaries per day in total (not counting on-demand ones).";
        };

      package = mkOption {
        type = types.package;
        readOnly = true;
        default = package;
        description = "`mailgate` (agents) and `mailgate-admin` (root).";
      };
    };

    agents = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options.mail = {
              enable = mkOption {
                type = types.bool;
                default = cfg.enable;
                defaultText = literalExpression "services.hyperhermes.mail.enable";
                description = "A mailbox <agent>@<mail.domain>: the `mailgate` and `himalaya` CLIs and the mailgate skill.";
              };
              owner = mkOption {
                type = types.str;
                default = if sso == null then name else sso.accounts.${name} or name;
                defaultText = literalExpression "services.hyperhermes.sso.accounts.<agent>, else the agent's name";
                description = "Login account that confirms this agent's allowlist requests on the owner page.";
              };
              allowlist = mkOption {
                type = types.listOf types.str;
                default = [ ];
                example = [
                  "boss@example.com"
                  "@example.org"
                ];
                description = "Senders that always reach the INBOX when DMARC passes; runtime entries add to these.";
              };
              passwordFile = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Runtime path of the mailbox's IMAP password (raw, root-readable); the agent gets its own copy.";
              };
            };
            config = lib.mkIf (cfg.enable && config.mail.enable) {
              extraPackages = [
                package
                himalaya
              ];
              skillDirs = [ "${skill}/share/skills" ];
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = exposure.enable && exposure.mode == "public";
            message = "services.hyperhermes.mail needs services.hyperhermes.exposure in public mode: the MX takes mail from the internet.";
          }
          {
            assertion = lib.all (s: s != null) (lib.attrValues cfg.secrets);
            message = "services.hyperhermes.mail.secrets: set master, hook, lmtp and csrf (nixosModules.clan does on a clan machine).";
          }
          {
            assertion = cfg.ownerPage.host != null -> frontDoorHost != null && cfg.ownerPage.cookieSecretFile != null;
            message = "services.hyperhermes.mail.ownerPage needs the sso front door (sso.frontDoor.host) and ownerPage.cookieSecretFile.";
          }
          {
            assertion = cfg.acme -> exposure.acme.dnsProvider != null;
            message = "services.hyperhermes.mail.acme needs services.hyperhermes.exposure.acme.dnsProvider.";
          }
          {
            assertion =
              !lib.any inStore (
                lib.filter (p: p != null) (
                  lib.attrValues cfg.secrets
                  ++ [
                    cfg.summarizer.keyFile
                    cfg.ownerPage.cookieSecretFile
                  ]
                  ++ lib.mapAttrsToList (_: m: m.passwordFile) mailboxes
                )
              );
            message = "services.hyperhermes.mail: secret files must be runtime paths outside the Nix store; the store is world-readable.";
          }
        ]
        ++ lib.mapAttrsToList (name: m: {
          assertion =
            builtins.match "[a-z][a-z0-9-]*" name != null
            && config.users.users ? ${name}
            && m.passwordFile != null;
          message = "services.hyperhermes.agents.${name}.mail: needs a lowercase name, a users.users account of that name and passwordFile (nixosModules.clan sets it).";
        }) mailboxes;

        users.users.mailgate = {
          isSystemUser = true;
          group = "mailgate";
        };
        users.groups.mailgate = { };

        environment.systemPackages = [
          package
          himalaya
        ];

        # Each agent's own copy of its IMAP password, for its himalaya. The
        # source is root-only; the copy is 0400 the agent's, in a 0500
        # directory of its own.
        systemd.services.mailgate-imap-passwords = {
          description = "Each mailbox agent's own copy of its IMAP password";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            LoadCredential = lib.mapAttrsToList (name: m: "imap-${name}:${m.passwordFile}") mailboxes;
          };
          path = [ pkgs.coreutils ];
          script = ''
            install -d -m 0755 ${passwordDir}
            ${lib.concatMapStrings (name: ''
              install -d -m 0500 -o ${name} -g root ${passwordDir}/${name}
              install -m 0400 -o ${name} -g root "$CREDENTIALS_DIRECTORY/imap-${name}" ${passwordDir}/${name}/password
            '') (lib.attrNames mailboxes)}
          '';
        };

        # DNS-01 like the published names' certificates.
        security.acme.certs.${cfg.hostname} = lib.mkIf cfg.acme (
          {
            inherit (exposure.acme) dnsProvider credentialFiles;
            # Stalwart reads the files at start (LoadCredential).
            reloadServices = [ "stalwart.service" ];
          }
          // lib.optionalAttrs (exposure.acme.dnsResolver != null) { inherit (exposure.acme) dnsResolver; }
        );

        services.stalwart = {
          enable = true;
          stateVersion = "26.05";
          # 0.15 refuses every next hop that resolves to loopback, relay
          # routes included, so the LMTP route to mailgate failed with
          # "host resolves loopback address". Upstream fixed it for relay
          # routes in 0.16, which services.stalwart does not support yet.
          # The test suite stays off: the nixpkgs package already skips its
          # outbound/LMTP tests, and checks/mail covers the route end to end.
          package = pkgs.stalwart.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./stalwart-relay-loopback.patch ];
            doCheck = false;
          });
          credentials = {
            master = cfg.secrets.master;
            hook = cfg.secrets.hook;
            lmtp = cfg.secrets.lmtp;
          }
          // lib.mapAttrs' (name: m: lib.nameValuePair "imap-${name}" m.passwordFile) mailboxes
          // lib.optionalAttrs (cfg.tls != null) {
            tls-cert = cfg.tls.certFile;
            tls-key = cfg.tls.keyFile;
          };
          settings = {
            server.hostname = cfg.hostname;
            # IPv4 only (the public address is sgp's, forwarded); IMAP on
            # loopback. No submission and no HTTP listener: no relay for
            # anyone and no management API or JMAP at all.
            server.listener = {
              smtp = {
                bind = [ "0.0.0.0:25" ];
                protocol = "smtp";
              };
              imap = {
                bind = [ "127.0.0.1:${toString imapPort}" ];
                protocol = "imap";
              };
            };
            server.tls = lib.mkIf (cfg.tls != null) {
              enable = true;
              implicit = false;
              certificate = "mx";
            };
            certificate = lib.mkIf (cfg.tls != null) {
              mx = {
                cert = "%{file:${credDir}/tls-cert}%";
                private-key = "%{file:${credDir}/tls-key}%";
                default = true;
              };
            };

            # The accounts: one per agent, no admin. mailgate logs into any
            # of them as `<agent>%mailgate` with the master secret.
            storage.directory = "agents";
            directory.agents = {
              type = "memory";
              principals = lib.mapAttrsToList (name: _: {
                class = "individual";
                inherit name;
                secret = "%{file:${credDir}/imap-${name}}%";
                email = [ "${name}@${cfg.domain}" ];
              }) mailboxes;
            };
            authentication.master = {
              user = "mailgate";
              secret = "%{file:${credDir}/master}%";
            };
            # The password travels over loopback only.
            imap.auth.allow-plain-text = true;

            # RCPT: mailgate's hook is the only judge of which local parts
            # exist (agents, live aliases); the directory is not consulted.
            # Anything outside the domain is refused as relay.
            session.rcpt = {
              directory = false;
              relay = [
                {
                  "if" = "rcpt_domain == '${cfg.domain}'";
                  "then" = true;
                }
                { "else" = false; }
              ];
              max-recipients = cfg.limits.maxRecipients;
            };
            # MAIL: the hook also refuses MAIL FROM and EHLO values outside a
            # dot-atom/hostname grammar. Stalwart copies both verbatim into
            # its Authentication-Results (smtp.mailfrom=, smtp.helo=, the SPF
            # comment), which mailgate then reads.
            session.hook.mailgate = {
              enable = true;
              url = "http://127.0.0.1:${toString hookPort}/hook";
              stages = [
                "mail"
                "rcpt"
              ];
              timeout = "15s";
              auth = {
                username = "stalwart";
                secret = "%{file:${credDir}/hook}%";
              };
              options.tempfail-on-error = true;
            };
            session.data = {
              limits.size = cfg.limits.messageBytes;
              spam-filter = false;
              # mailgate trusts only this header (the first one, carrying
              # this host's authserv-id); Stalwart's default, stated here so
              # no default change can drop it.
              add-headers.auth-results = true;
            };
            # Anyone on the internet can send here; these keep one sender
            # from filling Stalwart's queue and mailgate's disk. Every key
            # holds the remote IP: the MAIL FROM domain is unauthenticated
            # when Stalwart checks it (at MAIL, smtp/src/core/throttle.rs),
            # so a limit on it alone would let any host block a domain's mail
            # to every agent by sending under its name.
            queue.limiter.inbound = {
              mailgate-remote-ip = {
                key = [ "remote_ip" ];
                rate = "${toString cfg.limits.inboundPerIpHour}/1h";
                enable = true;
              };
              mailgate-sender-domain = {
                key = [
                  "remote_ip"
                  "sender_domain"
                ];
                rate = "${toString cfg.limits.inboundPerSenderDomainHour}/1h";
                enable = true;
              };
            };
            queue.quota.mailgate = {
              size = cfg.limits.queueBytes;
              messages = cfg.limits.queueMessages;
              enable = true;
            };
            # No spam filter: mailgate decides by allowlist and DKIM/DMARC alone.
            # On its first start Stalwart imports the rule set named here
            # OVER this file's settings (manager/boot.rs), and the stock set
            # turns on ASN/geo downloads and pyzor. An empty set keeps only
            # the version keys and Stalwart's built-in queue defaults.
            spam-filter = {
              enable = false;
              resource = "file://${pkgs.writeText "stalwart-no-spam-rules.toml" ''
                [version]
                spam-filter = "${config.services.stalwart.package.spam-filter.version}"
                server = "0.15.0"
              ''}";
              pyzor.enable = false;
            };
            asn.type = "disable";
            # Without an HTTP listener nothing serves it, but Stalwart still
            # loads it at start and would fetch it from GitHub otherwise.
            webadmin.resource = "file://${config.services.stalwart.package.webadmin}/webadmin.zip";

            # Mail whose sender's domain asks for p=reject and fails DMARC is
            # refused during the SMTP session; any other failure still lands
            # in quarantine (mailgate requires dmarc=pass for the INBOX).
            auth.dmarc.verify = "strict";

            # Every message, DSNs and reports included, goes to mailgate:
            # there is no route off this host.
            queue.strategy.route = "'mailgate'";
            queue.strategy.tls = "'local'";
            queue.route.mailgate = {
              type = "relay";
              # A name, not an IP literal: Stalwart passes the relay address
              # to a DNS lookup (mail-auth ipv4_lookup), and hickory answers
              # localhost itself (RFC 6761). A loopback next hop needs
              # ./stalwart-relay-loopback.patch.
              address = "localhost";
              port = lmtpPort;
              protocol = "lmtp";
              tls.implicit = false;
              auth = {
                username = "stalwart";
                secret = "%{file:${credDir}/lmtp}%";
              };
            };
            queue.tls.local = {
              dane = "disable";
              mta-sts = "disable";
              starttls = "disable";
            };
            report = {
              dkim.send = false;
              spf.send = false;
              dmarc.send = false;
              dmarc.aggregate.send = "never";
              tls.aggregate.send = "never";
            };
          };
        };

        systemd.services.stalwart = {
          after = [ "mailgate-firewall.service" ];
          requires = [ "mailgate-firewall.service" ];
          # The queue (raw mail before mailgate has it) lives here.
          serviceConfig.StateDirectoryMode = "0700";
        };

        networking.firewall.interfaces = lib.genAttrs cfg.smtpInterfaces (_: {
          allowedTCPPorts = [ 25 ];
        });

        systemd.sockets = lib.mapAttrs' (
          name: s:
          lib.nameValuePair "mailgate-${name}" {
            description = "mailgate ${name} socket";
            wantedBy = [ "sockets.target" ];
            listenStreams = [ s.listen ];
            socketConfig = {
              FileDescriptorName = name;
              Service = "mailgate.service";
            }
            // s.extra;
          }
        ) sockets;

        systemd.services.mailgate = {
          description = "mailgate: sanitizer, quarantine and allowlist of the agents' mail";
          wantedBy = [ "multi-user.target" ];
          requires = map (n: "mailgate-${n}.socket") (lib.attrNames sockets) ++ [
            "mailgate-firewall.service"
          ];
          after = map (n: "mailgate-${n}.socket") (lib.attrNames sockets) ++ [ "mailgate-firewall.service" ];
          environment.MAILGATE_CONFIG = configFile;
          serviceConfig = {
            ExecStart = "${python}/bin/python3 ${src}/mailgate.py";
            User = "mailgate";
            Group = "mailgate";
            Sockets = map (n: "mailgate-${n}.socket") (lib.attrNames sockets);
            StateDirectory = "mailgate";
            StateDirectoryMode = "0700";
            UMask = "0077";
            LoadCredential = [
              "master:${cfg.secrets.master}"
              "hook:${cfg.secrets.hook}"
              "lmtp:${cfg.secrets.lmtp}"
              "csrf:${cfg.secrets.csrf}"
            ]
            ++ lib.optional (
              cfg.summarizer.enable && cfg.summarizer.keyFile != null
            ) "p0:${cfg.summarizer.keyFile}";
            Restart = "always";
            RestartSec = 5;
            # The daemon plus at most three parse workers (./analyze.py, two
            # for delivery and one for agent requests, each capped by
            # limits.workerMemoryBytes): a flood of big mail runs into these,
            # not into the host.
            MemoryMax = "3G";
            TasksMax = 64;
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            CapabilityBoundingSet = "";
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
            ];
          };
        };

        # Rides its own unit like hermes-firewall (hyperhermes' core firewall),
        # with the same ordering: both firewall backends flush at start.
        systemd.services.mailgate-firewall = {
          description = "Owner-match and egress firewall of the agents' mail";
          wantedBy = [ "multi-user.target" ];
          after = [
            "userborn.service"
            "firewall.service"
            "nftables.service"
          ];
          before = [
            "stalwart.service"
            "mailgate.service"
          ];
          partOf =
            lib.optional config.networking.nftables.enable "nftables.service"
            ++ lib.optional (!config.networking.nftables.enable) "firewall.service";
          path = [ pkgs.iptables ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            for ipt in iptables ip6tables; do
              for c in mailgate-lo mailgate-egress; do
                $ipt -w -N $c 2>/dev/null || true
                $ipt -w -F $c
              done
            done
            iptables -w -N mailgate-mx 2>/dev/null || true
            iptables -w -F mailgate-mx
            ${gates}
            ${mxHairpin}
            for ipt in iptables ip6tables; do
              $ipt -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j mailgate-lo 2>/dev/null \
                || $ipt -w -I OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j mailgate-lo
            done
            iptables -w -C OUTPUT -p tcp --dport 25 -m conntrack --ctstate NEW -j mailgate-mx 2>/dev/null \
              || iptables -w -I OUTPUT -p tcp --dport 25 -m conntrack --ctstate NEW -j mailgate-mx
            for ipt in iptables ip6tables; do
              $ipt -w -A mailgate-egress -o lo -j RETURN
              $ipt -w -A mailgate-egress -p udp --dport 53 -j RETURN
              $ipt -w -A mailgate-egress -p tcp --dport 53 -j RETURN
              $ipt -w -A mailgate-egress -m owner --uid-owner mailgate -p tcp --dport ${toString cfg.summarizer.egressPort} -j RETURN
              $ipt -w -A mailgate-egress -j REJECT
              for u in ${stalwartUser} mailgate; do
                $ipt -w -C OUTPUT -m owner --uid-owner $u -m conntrack --ctstate NEW -j mailgate-egress 2>/dev/null \
                  || $ipt -w -I OUTPUT -m owner --uid-owner $u -m conntrack --ctstate NEW -j mailgate-egress
              done
            done
          '';
          preStop = ''
            iptables -w -D OUTPUT -p tcp --dport 25 -m conntrack --ctstate NEW -j mailgate-mx 2>/dev/null || true
            iptables -w -F mailgate-mx 2>/dev/null || true
            iptables -w -X mailgate-mx 2>/dev/null || true
            for ipt in iptables ip6tables; do
              $ipt -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j mailgate-lo 2>/dev/null || true
              for u in ${stalwartUser} mailgate; do
                $ipt -w -D OUTPUT -m owner --uid-owner $u -m conntrack --ctstate NEW -j mailgate-egress 2>/dev/null || true
              done
              for c in mailgate-lo mailgate-egress; do
                $ipt -w -F $c 2>/dev/null || true
                $ipt -w -X $c 2>/dev/null || true
              done
            done
          '';
        };
      }

      (lib.mkIf cfg.acme {
        systemd.services.stalwart = {
          wants = [ "acme-${cfg.hostname}.service" ];
          after = [ "acme-${cfg.hostname}.service" ];
        };
      })
    ]
  );
}
