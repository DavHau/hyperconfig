# roman's (./hermes-agents.nix) way into Roman's two Home Assistant
# instances, which are not clan machines: MCP plus the admin REST/WebSocket
# API with the same token, no ssh. Addressed on their LANs, which som
# reaches over zt-eu (../../home-networks): som is not a member of the old
# zerotier "home" net, and for roman's uid any destination without a
# main-table route goes into Mullvad
# (../../modules/nixos/mullvad-egress/egress.nix).
#   playa.bruch-bu.de  HA at 192.168.10.3
#   casa.bruch-bu.de   HA at 192.168.20.3
#
# Per instance, HA's "Model Context Protocol Server" integration as an MCP
# server (streamable HTTP at /api/mcp, hermes' default transport for a
# `url` entry), as HA user hermes-roman with a long-lived access token.
# The instances' state (that user, the integration) is declared in
# ../../home-assistant/hosts.nix; `nix run .#home-assistant-apply` converges
# it and mints the token into the var below when it is absent or invalid.
# The token rides secretEnv into roman's 0600 .env, and the header names it
# as ${VAR}: hermes interpolates url and headers of mcp_servers from the
# profile's .env and refuses to connect while one is unset (pinned v0.22.5,
# tools/mcp_tool_config.py _interpolate_env_vars and
# _require_rendered_remote), so the token never enters the store.
{ config, lib, ... }:
let
  agent = "roman";
  instances = {
    playa = {
      urlHost = "192.168.10.3";
      env = "HA_PLAYA_TOKEN";
    };
    casa = {
      urlHost = "192.168.20.3";
      env = "HA_CASA_TOKEN";
    };
  };
  generatorOf = name: "ha-${name}-token";
  vars = config.clan.core.vars.generators;
in
{
  clan.core.vars.generators = lib.mapAttrs' (
    name: _:
    lib.nameValuePair (generatorOf name) {
      # A persisted prompt IS the file: the var holds exactly the token.
      # home-assistant-apply sets it (`clan vars set som <generator>/token`).
      prompts.token = {
        type = "hidden";
        persist = true;
        description = "HA long-lived access token of user hermes-roman on ${name}.bruch-bu.de, for hermes agent ${agent} on som";
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
}
