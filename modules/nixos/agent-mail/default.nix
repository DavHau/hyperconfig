# Receive-only email for the native hermes agents (hyper.hermesAgents):
# <agent>@agents.davhau.com. ./mail.nix is the mechanism (Stalwart as MX,
# mailgate as sanitizer, quarantine, allowlist and alias registry); this file
# wires it into the host: clan vars, the MX certificate, the agent list, the
# agents' `mailgate` CLI and skill, and the owner page.
#
# DNS for davhau.com (tools/porkbun-dns, `porkbun-dns set <name> <type>
# <value>`). Nothing is ever sent from the domain, so SPF and DMARC say so:
#   mail.agents.davhau.com    A     38.89.142.76   (sgp, forwarded to som; no AAAA)
#   agents.davhau.com         MX    10 mail.agents.davhau.com
#   agents.davhau.com         TXT   "v=spf1 -all"
#   mail.agents.davhau.com    TXT   "v=spf1 -all"
#   _dmarc.agents.davhau.com  TXT   "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s"
#   *._domainkey.agents.davhau.com TXT "v=DKIM1; p="   (no key is valid)
# and PTR 38.89.142.76 -> mail.agents.davhau.com at sgp's provider if it
# allows one (senders may score a missing or mismatching PTR). The owner page
# rides the existing wildcard *.hermes.davhau.com records and certificate.
#
# Who confirms an allowlist request: the agent's owner, on
# https://mailgate.<dashboard host>/ (./owner-page.nix) behind its own
# pocket-id login: a second oauth2-proxy with a host-only `__Host-` session
# cookie and a fresh passkey check at every sign-in. The agent's uid holds
# no way in: the page's backend is a unix socket only nginx's group can
# connect to, no agent-controlled host ever receives that cookie, and nginx
# forwards no login cookie to agent backends at all
# (../hermes-dashboard-public.nix, ../hermes-agents-serve.nix). A separate
# origin plus an Origin check and a per-account token stop the agent's pages
# from driving the owner's browser. Root has `mailgate-admin` for the same
# decisions.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.agentMail;
  vars = config.clan.core.vars.generators;
  agents = config.hyper.hermesAgents;
  dashboard = config.hyper.hermesDashboard;
  ownerHost = "mailgate.${dashboard.host}";
  spacesOn = config.services.spaces-integrations.enable or false;
  random = len: ''openssl rand -hex ${toString len} | tr -d '\n' '';

  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "mailgate";
    src = pkgs.writeTextDir "SKILL.md" (
      builtins.replaceStrings [ "@DOMAIN@" ] [ cfg.domain ] (builtins.readFile ./skill/SKILL.md)
    );
  };
in
{
  imports = [
    ./mail.nix
    ./owner-page.nix
  ];

  config = lib.mkIf cfg.enable {
    clan.core.vars.generators = {
      # Root-only; Stalwart and mailgate get them as systemd credentials.
      mailgate = {
        files = lib.genAttrs [ "master" "hook" "lmtp" "csrf" ] (_: {
          restartUnits = [
            "stalwart.service"
            "mailgate.service"
          ];
        });
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        script = ''
          for f in master hook lmtp csrf; do
            ${random 32} > "$out/$f"
          done
        '';
      };
      # Shared var, same definition as ../hermes-agents-serve.nix; DNS-01
      # for the MX certificate reads it.
      porkbun = {
        share = true;
        prompts.apikey.type = "hidden";
        prompts.apikey.persist = true;
        prompts.secretkey.type = "hidden";
        prompts.secretkey.persist = true;
      };
    }
    # Per agent: its IMAP password. Root-only too; the spaces stager copies
    # it into the agent's own managed credential tree.
    // lib.mapAttrs' (
      name: _:
      lib.nameValuePair "mailgate-imap-${name}" {
        files.password.restartUnits = [
          "stalwart.service"
        ]
        ++ lib.optional spacesOn "spaces-integrations-managed-load.service";
        runtimeInputs = [
          pkgs.openssl
          pkgs.coreutils
        ];
        script = ''
          ${random 24} > "$out/password"
        '';
      }
    ) agents;

    hyper.agentMail = {
      agents = lib.mapAttrs (name: _: {
        owner = dashboard.users.${name}.account or name;
        passwordFile = vars."mailgate-imap-${name}".files.password.path;
      }) agents;
      secrets = lib.genAttrs [ "master" "hook" "lmtp" "csrf" ] (n: vars.mailgate.files.${n}.path);
      tls = {
        certFile = "/var/lib/acme/${cfg.hostname}/fullchain.pem";
        keyFile = "/var/lib/acme/${cfg.hostname}/key.pem";
      };
      # p0, as the agents' own brain (../hermes-common.nix); the token is
      # the shared inference var, read as a credential.
      summarizer = {
        enable = true;
        keyFile = vars.inference-api-key.files.token.path;
      };
      ownerPage.host = ownerHost;
      # sgp's address, forwarded here (../ipv4-forward.nix): agents must not
      # reach the MX through it as internet senders.
      mxAddresses = [ "38.89.142.76" ];
    };

    # DNS-01 like the serve wildcard: port 80 of the MX name is nobody's.
    security.acme.certs.${cfg.hostname} = {
      dnsProvider = "porkbun";
      credentialFiles = {
        PORKBUN_API_KEY_FILE = vars.porkbun.files.apikey.path;
        PORKBUN_SECRET_API_KEY_FILE = vars.porkbun.files.secretkey.path;
      };
      # Stalwart reads the files at start (LoadCredential).
      reloadServices = [ "stalwart.service" ];
    };
    systemd.services.stalwart = {
      wants = [ "acme-${cfg.hostname}.service" ];
      after = [ "acme-${cfg.hostname}.service" ];
    };

    services.hermes-native.extraPackages = [ cfg.package ];
    services.hermes-native.settings.skills.external_dirs = [ "${skill}/share/skills" ];
  };
}
