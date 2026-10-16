# Receive-only mailboxes for agents, without the secrets plumbing
# (./default.nix declares the clan vars and the host wiring; the VM test,
# ./test.nix, imports this file with plain files instead).
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
#   agent: reads its INBOX over IMAP on 127.0.0.1:143 (spaces mail tools,
#     profile "mailgate") with its own password, and everything else through
#     /run/mailgate/agent.sock, where the peer uid picks the mailbox.
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
# mailgate and root dial IMAP, and nobody but root reaches 587, where the
# agents' SMTP profile points so that sending fails at connect. Stalwart may
# open no connection off this host except DNS; mailgate only DNS and the
# summariser's port.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.hyper.agentMail;
  lmtpPort = 24;
  hookPort = 226;
  imapPort = 143;
  # The agents' SMTP profile points here. Nothing listens and the firewall
  # refuses everyone but root, so message_send fails at connect.
  closedSmtpPort = 587;
  stalwartUser = config.services.stalwart.user;
  credDir = "/run/credentials/stalwart.service";

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
      }) cfg.agents;
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
    # nginx alone (the owner page behind the dashboard login).
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
    gate ${toString imapPort} mailgate ${lib.concatStringsSep " " (lib.attrNames cfg.agents)}
  '';

  # When the MX's public address belongs to another host that forwards it
  # here (som: sgp's), this host's own traffic to it leaves over the uplink
  # and comes back like any internet sender's, past the loopback gate on 25.
  mxHairpin = lib.concatMapStrings (
    addr:
    lib.concatMapStrings (agent: ''
      iptables -w -A mailgate-mx -d ${addr} -p tcp --dport 25 -m owner --uid-owner ${agent} -j REJECT --reject-with tcp-reset
    '') (lib.attrNames cfg.agents)
  ) cfg.mxAddresses;
in
{
  options.hyper.agentMail = with lib; {
    enable = mkEnableOption "receive-only mailboxes for the agents";

    domain = mkOption {
      type = types.str;
      default = "agents.davhau.com";
      description = "Mail domain: every agent receives at <agent>@<domain>.";
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

    agents = mkOption {
      default = { };
      description = "Mailboxes; the name is the local part and the unix account that may use the mailbox.";
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              owner = mkOption {
                type = types.str;
                default = name;
                description = "Dashboard (pocket-id) account that confirms this agent's allowlist requests.";
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
                type = types.str;
                description = "IMAP password of the mailbox (raw, root-readable).";
              };
            };
          }
        )
      );
    };

    secrets = mkOption {
      description = "Root-readable files with the internal shared secrets.";
      type = types.submodule {
        options = lib.genAttrs [ "master" "hook" "lmtp" "csrf" ] (
          n:
          mkOption {
            type = types.str;
            description = "Secret `${n}`.";
          }
        );
      };
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
      default = null;
      description = "Certificate for STARTTLS on the MX; null offers no TLS.";
    };

    summarizer = {
      enable = mkEnableOption "summaries of quarantined mail by a tool-less model";
      url = mkOption {
        type = types.str;
        default = "https://inference.p0.contact/v1";
        description = "OpenAI-compatible base URL.";
      };
      model = mkOption {
        type = types.str;
        default = "qwen";
      };
      keyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Bearer token file (root-readable).";
      };
      egressPort = mkOption {
        type = types.port;
        default = 443;
        description = "The only TCP port mailgate may dial off this host.";
      };
    };

    ownerPage.host = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Public host of the owner page; the CSRF origin check and the links in request answers use it.";
    };

    mxAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "38.89.142.76" ];
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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = lib.mapAttrsToList (name: _: {
          assertion = builtins.match "[a-z][a-z0-9-]*" name != null && config.users.users ? ${name};
          message = "hyper.agentMail.agents.${name}: needs a lowercase name and a users.users account of that name.";
        }) cfg.agents;

        users.users.mailgate = {
          isSystemUser = true;
          group = "mailgate";
        };
        users.groups.mailgate = { };

        environment.systemPackages = [ package ];

        services.stalwart = {
          enable = true;
          stateVersion = "26.05";
          # 0.15 refuses every next hop that resolves to loopback, relay
          # routes included, so the LMTP route to mailgate failed with
          # "host resolves loopback address". Upstream fixed it for relay
          # routes in 0.16, which services.stalwart does not support yet.
          # The test suite stays off: the nixpkgs package already skips its
          # outbound/LMTP tests, and ./test.nix covers the route end to end.
          package = pkgs.stalwart.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./stalwart-relay-loopback.patch ];
            doCheck = false;
          });
          credentials = {
            master = cfg.secrets.master;
            hook = cfg.secrets.hook;
            lmtp = cfg.secrets.lmtp;
          }
          // lib.mapAttrs' (name: a: lib.nameValuePair "imap-${name}" a.passwordFile) cfg.agents
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
              }) cfg.agents;
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

        # Rides its own unit like hermes-firewall (../hermes-native/firewall.nix),
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

      # Each agent's INBOX as a Nix-managed profile of the spaces mail
      # integration. Its SMTP side points at the closed port: the
      # integration has no read-only mode, and a refused connect is the
      # cleanest failure message_send can give.
      (lib.optionalAttrs (options ? spaces) {
        spaces.users = lib.mapAttrs (name: a: {
          integrations.mail.profiles.mailgate = {
            config = {
              email = "${name}@${cfg.domain}";
              display_name = name;
              imap_host = "127.0.0.1";
              imap_port = toString imapPort;
              imap_encryption = "none";
              imap_login = name;
              smtp_host = "127.0.0.1";
              smtp_port = toString closedSmtpPort;
              smtp_encryption = "none";
              smtp_login = name;
            };
            secrets.password.file = a.passwordFile;
          };
        }) cfg.agents;
        # These are the first Nix-managed profiles on this host, and spaces'
        # stager script (spaces-integrations/default.nix, perIntegrationScript)
        # writes each TOML line with its own `>> "$cttmp"`. Under spaces'
        # systemd.enableStrictShellChecks that style warning (SC2129) fails
        # the build. spaces' own tests never build the script. Drop this
        # once spaces groups the redirects.
        systemd.services.spaces-integrations-managed-load.enableStrictShellChecks = false;

        # The integration unit loads the broker's own store (config.toml and
        # a sealed secrets blob) as credentials next to the managed tree, and
        # a missing source fails it with 243/CREDENTIALS. The broker writes
        # that store only when someone sets an account in the Integrations
        # app, which never happens for an agent whose only account is this
        # managed one; so the mail tools never came up. Seed an empty store,
        # sealed the way the broker seals it, before the unit starts.
        systemd.user.services.agent-mail-store-seed = {
          description = "Seed an empty spaces mail store for an agent mailbox";
          wantedBy = [ "spaces-integration-mail.service" ];
          before = [ "spaces-integration-mail.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            case "$(${pkgs.coreutils}/bin/id -un)" in
              ${lib.concatStringsSep "|" (lib.attrNames cfg.agents)}) ;;
              *) exit 0 ;;
            esac
            dir="''${XDG_STATE_HOME:-$HOME/.local/state}/spaces-integrationd/mail"
            ${pkgs.coreutils}/bin/mkdir -p "$dir"
            ${pkgs.coreutils}/bin/chmod 0700 "$dir"
            [ -e "$dir/config.toml" ] || : > "$dir/config.toml"
            if [ ! -e "$dir/secrets" ]; then
              empty=$(${pkgs.coreutils}/bin/mktemp)
              ${pkgs.systemd}/bin/systemd-creds encrypt --user --uid=self --with-key=host+tpm2 \
                --name=secrets "$empty" "$dir/secrets"
              ${pkgs.coreutils}/bin/rm -f "$empty"
            fi
          '';
        };
      })
    ]
  );
}
