/*
  The infra agent's OpenAI-compatible api_server, for som's voice-gateway
  only (../voice-gateway: Dave's trusted voice mode), plus the MCP server
  of that gateway (its voice_trusted_mode_off tool).

  hermes' api_server binds 127.0.0.1:8642 in the guest (its default); a
  socket proxy on the guest's veth address, port `port`, forwards to it, as
  the dashboard's does (./hermes.nix). Who can reach it:
    - in the guest: an owner gate on 8642 admitting the proxy, root and
      infra (hermes' own wake self-posts; infra can read its .env anyway),
    - from the host: only root and the voice-gateway uid
      (hyper.infraSpace.extraToGuestRules, ./default.nix's output gate),
    - and the bearer key API_SERVER_KEY (the credential voice-api-key).
  The gateway always sends X-Hermes-Session-Id: voice, so voice turns land
  in their own session, never in Dave's chats. The platform is unattended
  for hermes' approval gate (dangerous commands are denied by default, not
  asked), so destructive work still needs Dave's normal chat.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.infraSpace.voiceApi;
  credential = name: "/run/credentials/@system/${name}";
  proxyUser = "infra-space-voice";
  apiPort = 8642;
in
{
  options.infraSpace.voiceApi = {
    enable = lib.mkEnableOption "the infra agent's api_server for the voice-gateway";
    listenAddress = lib.mkOption {
      type = lib.types.str;
      description = "The guest's veth address the host's voice-gateway dials.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9123;
    };
    mcpUrl = lib.mkOption {
      type = lib.types.str;
      description = "The voice-gateway's MCP endpoint (the host's veth address).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.hyperhermes.agents.infra = {
      environment = {
        API_SERVER_HOST = "127.0.0.1";
        API_SERVER_PORT = toString apiPort;
        API_SERVER_MODEL_NAME = "infra";
      };
      secretEnv = {
        API_SERVER_KEY = credential "voice-api-key";
        VOICE_MCP_TOKEN = credential "voice-mcp-token";
      };
      settings.mcp_servers.voice-gateway = {
        url = cfg.mcpUrl;
        headers.Authorization = "Bearer \${VOICE_MCP_TOKEN}";
      };
    };

    users.users.${proxyUser} = {
      isSystemUser = true;
      group = proxyUser;
    };
    users.groups.${proxyUser} = { };
    systemd.sockets.infra-space-voice-api = {
      description = "infra agent api_server for the host's voice-gateway";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "${cfg.listenAddress}:${toString cfg.port}" ];
      socketConfig.FreeBind = true;
    };
    systemd.services.infra-space-voice-api = {
      description = "Forward the host's voice-gateway to the infra agent's api_server";
      serviceConfig = {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd 127.0.0.1:${toString apiPort}";
        User = proxyUser;
        Group = proxyUser;
        PrivateTmp = true;
      };
    };
    # Only the proxy, root and infra (hermes' own wake self-posts) dial the
    # api_server inside the guest.
    systemd.services.hermes-firewall.script = lib.mkAfter ''
      iptables -w -A ${inputs.hyperhermes.lib.chain} -p tcp --dport ${toString apiPort} -m owner --uid-owner ${proxyUser} -j RETURN
      iptables -w -A ${inputs.hyperhermes.lib.chain} -p tcp --dport ${toString apiPort} -m owner --uid-owner infra -j RETURN
      iptables -w -A ${inputs.hyperhermes.lib.chain} -p tcp --dport ${toString apiPort} -m owner --uid-owner 0 -j RETURN
      iptables -w -A ${inputs.hyperhermes.lib.chain} -p tcp --dport ${toString apiPort} -j REJECT --reject-with tcp-reset
    '';
  };
}
