# cm-pi's part of ./default.nix: Home Assistant's conversation agent
# hermes_conversation (./hermes_conversation), which forwards every Assist
# turn to som's voice-gateway with the shared secret voice-gateway-ha
# (./shared-vars.nix, readable by hass only), and HA's MCP server
# integration (mcp_server), which the `voice` hermes agent uses as the
# non-admin HA user voice-agent.
#
# HA state set through its API, not here (config = null on this host):
# the hermes_conversation config entry (url, secret_file below), the
# mcp_server entry (Assist API, require_admin off), the users voice-agent
# and voice-gateway (non-admin), the "Local (vit)" pipeline's
# conversation_engine. The entry's secret_file is this var's path,
# /run/secrets/shared/voice-gateway-ha/secret.
{ pkgs, ... }:
let
  component = pkgs.buildHomeAssistantComponent {
    owner = "hyperconfig";
    domain = "hermes_conversation";
    version = "1.0.0";
    src = ./hermes_conversation;
  };
in
{
  imports = [ ./shared-vars.nix ];

  clan.core.vars.generators.voice-gateway-ha.files.secret = {
    owner = "hass";
    restartUnits = [ "home-assistant.service" ];
  };

  services.home-assistant.customComponents = [ component ];
  services.home-assistant.extraComponents = [ "mcp_server" ];
}
