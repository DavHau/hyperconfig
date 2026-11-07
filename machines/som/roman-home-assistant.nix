# roman's (./hermes-agents.nix) way into Roman's two Home Assistant
# instances, which are not clan machines:
#   playa.bruch-bu.de  HA at 192.168.194.30, on the zerotier "home" net
#                      (af415e486f4514ce, which every machine joins,
#                      ../../modules/nixos/common.nix),
#   casa.bruch-bu.de   HA at fcc0:044a:8669:8c81:6d54::1, that net's 6plane.
# The public names resolve to edi, which proxies only :8123
# (../edi/reverse-proxy.nix), so ssh and the API go to the overlay
# addresses. roman's uid leaves through Mullvad, whose kill switch passes
# 192.168.0.0/16 and fc00::/7 directly, and its uid rule still uses every
# non-default route of the main table, the zerotier ones included
# (../../modules/nixos/mullvad-egress/egress.nix).
#
# Per instance:
#   - ssh as root to its SSH add-on with roman's own key (clan var
#     hermes-agent-ssh-roman, hyperhermes.nixosModules.clan): `ssh playa`,
#     `ssh casa`. Not services.hyperhermes.sshKeyHosts: that hands the
#     hosts to every agent's key.
#   - HA's "Model Context Protocol Server" integration as an MCP server
#     (streamable HTTP at /api/mcp, hermes' default transport for a `url`
#     entry), with a long-lived access token Dave enters once:
#         clan vars generate som --generator ha-playa-token
#         clan vars generate som --generator ha-casa-token
#     The token rides secretEnv into roman's 0600 .env, and the header names
#     it as ${VAR}: hermes interpolates url and headers of mcp_servers from
#     the profile's .env and refuses to connect while one is unset (pinned
#     v0.22.5, tools/mcp_tool_config.py _interpolate_env_vars and
#     _require_rendered_remote), so the token never enters the store.
{ config, lib, ... }:
let
  agent = "roman";
  instances = {
    playa = {
      address = "192.168.194.30";
      urlHost = "192.168.194.30";
      env = "HA_PLAYA_TOKEN";
    };
    casa = {
      address = "fcc0:044a:8669:8c81:6d54::1";
      urlHost = "[fcc0:044a:8669:8c81:6d54::1]";
      env = "HA_CASA_TOKEN";
    };
  };
  generatorOf = name: "ha-${name}-token";
  vars = config.clan.core.vars.generators;
  home = config.users.users.${agent}.home;
in
{
  clan.core.vars.generators = lib.mapAttrs' (
    name: _:
    lib.nameValuePair (generatorOf name) {
      # A persisted prompt IS the file: the var holds exactly the token.
      prompts.token = {
        type = "hidden";
        persist = true;
        description = "HA long-lived access token (profile -> security) of ${name}.bruch-bu.de, for hermes agent ${agent} on som";
      };
      # Root-only: the agent unit's LoadCredential reads it.
      files.token.restartUnits = [ "hermes-agent-${agent}.service" ];
    }
  ) instances;

  services.hyperhermes.agents.${agent} = {
    secretEnv = lib.mapAttrs' (
      name: i: lib.nameValuePair i.env vars.${generatorOf name}.files.token.path
    ) instances;
    settings.mcp_servers = lib.mapAttrs' (
      name: i:
      lib.nameValuePair "ha-${name}" {
        url = "http://${i.urlHost}:8123/api/mcp";
        headers.Authorization = "Bearer \${${i.env}}";
      }
    ) instances;
  };

  # In the system ssh_config, which the agent cannot edit, and only for
  # roman's own logins. originalhost: the alias as typed, before HostName.
  # The add-ons' host keys are unknown until Roman sets them up, so these
  # two hosts alone accept a new key on first contact (into roman's
  # ~/.ssh/known_hosts) and refuse a changed one afterwards.
  programs.ssh.extraConfig = lib.concatStrings (
    lib.mapAttrsToList (name: i: ''
      Match originalhost ${name} localuser ${agent}
        HostName ${i.address}
        User root
        Port 22
        IdentityFile ${config.services.hyperhermes.agents.${agent}.sshKeyFile}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
    '') instances
  );

  # ../../modules/nixos/ssh.nix sets ControlPath ~/.ssh/control/%C
  # fleet-wide; without the directory every ssh fails. roman is not in
  # ./hermes-agents-data.nix, whose agents get these from
  # ./hermes-agents.nix.
  systemd.tmpfiles.rules = [
    "d ${home}/.ssh 0700 ${agent} users -"
    "d ${home}/.ssh/control 0700 ${agent} users -"
  ];
}
