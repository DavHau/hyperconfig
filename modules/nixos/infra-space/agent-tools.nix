/*
  The infra agent's tools for web signups (som only, ./agent-tools-guest.nix
  in the guest): a receive-only mailbox, a confined browser and the shared
  Lightning wallet, each the existing hyperhermes feature of som's agents,
  served on this host and offered to the container over its veth, as the
  voice-gateway's MCP is (../voice-gateway).

  Host side, all on the host's veth address 10.235.0.1:
    - mail: hyperhermes mail's remoteMailboxes.infra, owner Dave (his
      pocket-id account `dave` whitelists senders on the owner page): the
      mailbox infra@<mail domain>, Stalwart account and mailgate allowlist
      exactly as an agent's. Its identity here is the system user `infra`
      (uid 1216; no login, no home, nothing else), whose uid mailgate's
      agent socket and the IMAP gate know. Two socket proxies dial as that
      user: mailPort to /run/mailgate/agent.sock (mailgate's agent API:
      status, inbox, quarantine view, allowlist requests, aliases; nothing
      that sends), imapPort to Stalwart's 127.0.0.1:143 (read-only
      sanitized copies, its own password, the clan var mailgate-imap-infra,
      passed as the credential `mail-imap`). Receive-only like every
      agent's mailbox: no SMTP anywhere, and only allowlisted senders with
      DMARC pass reach the INBOX. Mail is untrusted input for an agent
      with fleet root: allowDomains = false, so mailgate refuses
      whole-domain (`@domain`) entries for this mailbox, on the owner
      page, from mailgate-admin, in requests and in Nix; and the agent
      reads mail only in a delegated child and never acts on
      instructions found in it (./hermes-skill/SKILL.md).
    - browser, only with hyper.infraSpace.agentTools.browser (default
      off; off means none of what follows exists, here or in the guest:
      no server, user, key, credential, port, egress rule, plugin or
      toolset): hyperhermes browser's extraServers.infra-browser: a Camofox
      server (camofox-browser + Camoufox, CaptchaKraken on vit for
      browser_solve_captcha) as the system user `infra-browser` (uid 1217),
      reached through core's owner-checking bridge on browserPort, its
      access key the credential `camofox-key`. It runs on this host, not in
      the container, so nothing it renders or runs can read the guest's
      files: none of infra's keys (fleet ssh, GitHub, clan age identity)
      are reachable from its uid, and the unit cannot even see the
      container's directories (InaccessiblePaths). Egress: Mullvad only
      (hyper.mullvadEgress, its DNS through the tunnel too), and this
      module's own table refuses everything else of its uid: no LAN, no
      mesh, no loopback service, no host address; only the tunnel,
      Mullvad's in-tunnel DNS stub (127.0.0.153:53), its own backend port
      and CaptchaKraken on vit (ygg, 8096).
    - wallet: walletPort proxied to phoenixd's API on 127.0.0.1:9740; the
      API password (phoenixd-api's phoenix.conf, which som's wallet agents
      read through the lightning-wallet group) as the credential
      `phoenix.conf`. The same full access as every wallet agent's, the
      shared float, nothing more: the cap is the float itself.
    - Who dials these ports: the container through the veth (the firewall
      opens them on ve-infra-space only), and on this host root alone (the
      output gate below; lo is otherwise open to every uid, and other
      tenants' agents must not borrow infra's mailbox, browser or wallet).
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.infraSpace.agentTools;
  hlib = inputs.hyperhermes.lib;
  vars = config.clan.core.vars.generators;
  containerUnit = "container@infra-space.service";
  vethHost = config.containers.infra-space.hostAddress;

  mailUser = "infra";
  mailUid = 1216; # ../vault-ids.nix ladder
  browserUser = "infra-browser";
  browserUid = 1217;

  mailPort = 9141;
  imapPort = 9142;
  walletPort = 9143;
  browserPort = 9144;
  ports = [
    mailPort
    imapPort
    walletPort
  ]
  ++ lib.optional cfg.browser browserPort;
  portSet = "{ ${lib.concatMapStringsSep ", " toString ports} }";

  vitYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "vit";
    generator = "yggdrasil";
    file = "address";
  };

  # Never the browser's: what mullvad-egress lets its users reach off the
  # tunnel (private, link-local, multicast, yggdrasil, retiolum) and its
  # directPrefixes (the LAN's public /64).
  private4 = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "255.255.255.255"
  ];
  private6 = [
    "::1"
    "fc00::/7"
    "fe80::/10"
    "ff00::/8"
    "200::/7"
    "42::/16"
  ];
  directPrefixes = config.hyper.mullvadEgress.directPrefixes;
  direct4 = lib.filter (p: !lib.hasInfix ":" p) directPrefixes;
  direct6 = lib.filter (lib.hasInfix ":") directPrefixes;

  mail = config.services.hyperhermes.mail;
  browser = config.services.hyperhermes.browser.extraServers.${browserUser};

  # The browser: the internet only, which mullvad-egress then forces
  # through the tunnel (its kill switch passes LAN, mesh and loopback;
  # this does not). Its WireGuard packets to the relays carry this uid
  # too: public addresses, so they pass.
  browserChain = ''
    chain browser {
      # Replies of connections others opened to it (the bridge's to its
      # server's listener and backend port) carry its uid too; they open
      # nothing new.
      ct state established,related accept
      oifname "lo" ip daddr 127.0.0.153 meta l4proto { tcp, udp } th dport 53 accept
      oifname "lo" ip daddr 127.0.0.1 tcp dport ${
        toString (hlib.camofoxBackendBase + browserUid)
      } accept
      ip6 daddr ${vitYgg} tcp dport 8096 accept
      oifname "lo" jump refuse
      oifname "wg-mullvad" accept
      ip daddr { ${lib.concatStringsSep ", " (private4 ++ direct4)} } jump refuse
      ip6 daddr { ${lib.concatStringsSep ", " (private6 ++ direct6)} } jump refuse
      ip daddr ${vethHost} jump refuse
    }
  '';

  proxy = name: description: target: user: {
    sockets."infra-space-${name}" = {
      inherit description;
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${vethHost}:${toString target.port}" ];
      socketConfig.FreeBind = true;
    };
    services."infra-space-${name}" = {
      description = "${description} (proxy)";
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${target.to}";
        PrivateTmp = true;
      }
      // (
        if user == null then
          { DynamicUser = true; }
        else
          {
            User = user;
            Group = user;
          }
      );
    };
  };
  proxies = [
    (proxy "mail" "infra's mailgate agent socket for the container" {
      port = mailPort;
      to = "/run/mailgate/agent.sock";
    } mailUser)
    (proxy "imap" "infra's IMAP mailbox for the container" {
      port = imapPort;
      to = "127.0.0.1:143";
    } mailUser)
    (proxy "wallet" "the shared phoenixd API for the container" {
      port = walletPort;
      to = "127.0.0.1:9740";
    } null)
  ];
in
{
  options.hyper.infraSpace.agentTools.browser = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Give the infra agent the Camofox browser (the infra-browser server
      on this host, its key, port and egress rules, and in the guest the
      camofox plugin and toolset). Off: none of it exists, on either side.
      Web pages are prompt injection aimed at an agent holding fleet root.
    '';
  };

  config = lib.mkMerge [
    {
      users.users.${mailUser} = {
        isSystemUser = true;
        uid = mailUid;
        group = mailUser;
        description = "infra-space agent's mailbox (mailgate identity only)";
      };
      users.groups.${mailUser}.gid = mailUid;

      # Mail is untrusted input for an agent with fleet root: senders are
      # allowlisted one address at a time, never a whole domain (anyone
      # with an address there could then write to it).
      services.hyperhermes.mail.remoteMailboxes.${mailUser} = {
        owner = "dave";
        allowDomains = false;
      };

      systemd.sockets = lib.mkMerge (map (p: p.sockets) proxies);
      systemd.services = lib.mkMerge (map (p: p.services) proxies);

      clan.core.vars.generators."mailgate-imap-${mailUser}".files.password.restartUnits = [
        containerUnit
      ];
      clan.core.vars.generators.phoenixd-api.files."phoenix.conf".restartUnits = [ containerUnit ];
      hyper.infraSpace.credentials = {
        mail-imap = mail.remoteMailboxes.${mailUser}.passwordFile;
        "phoenix.conf" = config.services.hyperhermes.wallet.apiConfigFile;
      };

      hyper.infraSpace.guestModules = [
        {
          imports = [ ./agent-tools-guest.nix ];
          infraSpace.agentTools = {
            enable = true;
            browser = cfg.browser;
            inherit
              vethHost
              mailPort
              imapPort
              walletPort
              browserPort
              ;
            mailDomain = mail.domain;
            mailgate = mail.package;
            inherit (mail.clientPackages) himalaya;
            mailSkill = mail.clientPackages.skill;
            walletSkill = config.services.hyperhermes.wallet.clientPackages.skill;
            camofoxPlugin = pkgs.callPackage "${inputs.hyperhermes}/pkgs/hermes-camofox-plugin" { };
            phoenixd = config.services.hyperhermes.wallet.package;
          };
        }
      ];

      networking.firewall.interfaces."ve-infra-space".allowedTCPPorts = ports;

      networking.nftables.tables.infra-space-agent-tools = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            # These ports serve the container only; on this host root alone.
            ip daddr ${vethHost} tcp dport ${portSet} ct state new meta skuid != 0 reject with tcp reset
            ${lib.optionalString cfg.browser "meta skuid ${toString browserUid} jump browser"}
          }
          ${lib.optionalString cfg.browser browserChain}
          chain refuse {
            meta l4proto tcp reject with tcp reset
            reject with icmpx admin-prohibited
          }
        '';
      };
    }

    (lib.mkIf cfg.browser {
      users.users.${browserUser} = {
        isSystemUser = true;
        uid = browserUid;
        group = browserUser;
        description = "infra-space agent's Camofox browser";
      };
      users.groups.${browserUser}.gid = browserUid;

      services.hyperhermes.browser.extraServers.${browserUser}.listen =
        "${vethHost}:${toString browserPort}";

      systemd.services = {
        "hermes-camofox-${browserUser}".serviceConfig.InaccessiblePaths = [
          "-/var/lib/nixos-containers"
          "-/var/lib/infra-space"
          "-/run/mailgate"
          "-/run/secrets"
        ];
        # nspawn reads the key at the container's start.
        ${"container@infra-space"} = {
          wants = [ "hermes-camofox-key-${browserUser}.service" ];
          after = [ "hermes-camofox-key-${browserUser}.service" ];
        };
      };

      # The browser's state directory, as core makes an agent's (root's 0711
      # parent, the owner's 0700 state).
      systemd.tmpfiles.rules = [
        "d ${hlib.baseDir browserUser} 0711 root root - -"
        "d ${hlib.stateDir browserUser} 0700 ${browserUser} ${browserUser} - -"
      ];

      hyper.mullvadEgress = {
        users = [ browserUser ];
        dns.services = [ "hermes-camofox-${browserUser}" ];
      };

      hyper.infraSpace.credentials.camofox-key = browser.keyFile;
    })
  ];
}
