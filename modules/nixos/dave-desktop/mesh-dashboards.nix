/*
  Dave's hermes apps reach the dashboards over yggdrasil, not the public
  internet: on a desktop (not som, which serves them), every name the
  apps open resolves to the serving machine's yggdrasil address, through
  /etc/hosts:
    - https://<agent>.davhau.fyi for each of som's agents
      (machines/som/hermes-dashboards.nix) and infra-space
      (../infra-space/dashboard-account.nix), and the front door
      hermes.davhau.com: som;
    - the sign-in, id.davhau.com (pocket-id, modules/clan/oidc): edi.
  Same URLs, same certificates (nginx on both answers on [::]:443 for
  those names, and the clan's yggdrasil filter there admits this
  machine's address); the sign-in and the dashboards' rate limits see this
  machine's yggdrasil address, one /128 shared by this host and all its
  containers (as its public v4 was). Serve ports (<port>.<agent>.davhau.fyi)
  and everything else stay on public DNS.

  The containers here resolve through this host's resolved stub
  (../spaces/host.nix), which answers from /etc/hosts too, so the
  isolated apps (./isolated-apps.nix), infra-space and the spaces get the
  same addresses; their packets leave masqueraded to this host's
  yggdrasil address. A confined guest may reach yggdrasil only at
  `endpoints` (each address, tcp 443; ../spaces/host.nix `confine`).

  Without yggdrasil (its interface down) a connect fails at once (no
  route); with the interface up but no path to the peer it waits for the
  app's timeout: yggdrasil gives no ICMP answer for a lost path. The
  entries are authoritative (no fallback to the public addresses), so
  then every login through id.davhau.com from this machine fails too.
*/
{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.hyper.meshDashboards;
  dashboards = import ../../../machines/som/hermes-dashboards.nix;
  infraSpaceAccount = import ../infra-space/dashboard-account.nix;
  machine = config.clan.core.settings.machine.name;
  yggAddress =
    m:
    inputs.clan-core.clanLib.getPublicValue {
      flake = config.clan.core.settings.directory;
      machine = m;
      generator = "yggdrasil";
      file = "address";
    };
  # serving machine -> its names
  names = {
    som =
      map (agent: "${agent}.${dashboards.domain}") (
        lib.attrNames dashboards.accounts ++ [ infraSpaceAccount.name ]
      )
      ++ [ dashboards.frontDoor ];
    edi = [ "id.davhau.com" ];
  };
in
{
  options.hyper.meshDashboards = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = !(lib.hasAttr machine names);
      defaultText = lib.literalMD "true but on the serving machines (som, edi)";
      description = "Resolve the hermes dashboards' and their sign-in's names to the serving machines' yggdrasil addresses.";
    };
    endpoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.optionals cfg.enable (map yggAddress (lib.attrNames names));
      description = "The yggdrasil addresses the names resolve to; confined guests may reach these on tcp 443 (../spaces/host.nix).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.hosts = lib.mapAttrs' (m: ns: lib.nameValuePair (yggAddress m) ns) names;
  };
}
