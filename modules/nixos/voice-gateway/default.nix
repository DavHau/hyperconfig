/*
  voice-gateway (som): Home Assistant's Voice PE talks to hermes.

    satellite -> HA "Local (vit)" pipeline (STT/TTS on vit) -> conversation
    agent hermes_conversation (./hermes_conversation, on cm-pi: ./cm-pi.nix)
    -> POST [som ygg]:haPort/v1/converse (shared secret, cm-pi's ygg
    address only) -> ./gateway.py -> one of
      untrusted (default): the `voice` hermes agent's api_server
        (../../../machines/som/hermes-agents.nix; HA through its MCP server as
        the non-admin HA user voice-agent, ./voice-agent.nix),
      trusted: the infra agent's api_server in the infra-space container
        (../infra-space/voice-api.nix), session `voice`.

  Trusted mode is bound to the satellite device that asked and ends after
  idleMinutes without a request from it, or when an agent calls the MCP
  tool voice_trusted_mode_off (served here on mcpPort, one bearer token per
  agent; there is no unlock tool). Unlock:
    - passkey: "unlock" -> ntfy push (edi, ./edi.nix) with a one-time link
      https://voice.davhau.com/unlock/<id> (2 min, single use, 3 per 10 min)
      -> pocket-id with prompt=login&max_age=0 (pocket-id re-authenticates
      with a passkey assertion that requires user verification, its
      default) -> the callback checks nonce, auth_time within 60 s, user
      dave, group voice;
    - voice code: the start phrase -> two rounds of "<p1>, <p2>." answered
      with (code[p1] + code[p2]) mod 10; handled here, never forwarded to an
      agent or logged. 2 wrong answers lock it until the next passkey
      unlock; after maxUses successes it needs a new code. The code is the
      clan var voice-unlock-code on first start, then
      /var/lib/voice-gateway/state.json (0600, authoritative after a
      rotation); https://voice.davhau.com/code shows it after a fresh
      passkey login and can generate a new one.
  Every trusted request is logged to the journal (timestamp, transcript).

  Follow-up listening (gateway.py `turn`): /v1/converse answers
  {speech, continue_conversation}; hermes_conversation hands the flag to
  HA, and the satellite reopens its microphone without the wake word. Set
  when the agent ends its reply with the marker [listen] (a real question,
  choice or confirmation; a bare "?" does not count), or in conversation
  mode ("let's talk" / "lass uns reden" ... "that's all" / "das war's",
  per device, ends after 5 min or on a silent/filler follow-up). Outside
  conversation mode at most 10 follow-ups in a row; filler transcripts
  ("you", "Oh.") on a reopened mic end the chain unanswered. Every user
  message carries the current local time.

  Listeners: haPort and webPort on som's ygg address, admitted from cm-pi's
  and edi's ygg addresses respectively; mcpPort on 127.0.0.1 (the voice
  agent) and the infra-space veth host address (the infra agent). Local
  uids other than root and the agents reach the ygg listeners only through
  their secrets (the ha secret, OIDC); the nft output rule below refuses
  them anyway.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.voiceGateway;
  vars = config.clan.core.vars.generators;
  hlib = inputs.hyperhermes.lib;
  user = "voice-gateway";
  uid = 1209; # ../vault-ids.nix ladder
  ygg =
    machine:
    inputs.clan-core.clanLib.getPublicValue {
      flake = config.clan.core.settings.directory;
      inherit machine;
      generator = "yggdrasil";
      file = "address";
    };
  somYgg = ygg "som";
  cmPiYgg = ygg "cm-pi";
  ediYgg = ygg "edi";
  vethHost = config.containers.infra-space.hostAddress;
  infraGuest = config.containers.infra-space.localAddress;

  # The voice agent's api_server: a root-held loopback port bridged to the
  # agent's backend (hyperhermes' forwards: nobody else can squat it while
  # the agent is down), owner-only plus this service's uid.
  apiBackendBase = 26000;
  # The infra agent's api_server proxy on the guest's veth address.
  voiceApiPort = 9123;
  apiPort = 28642;
  voiceUid = config.services.hyperhermes.agents.voice.uid;

  cred = name: "/run/credentials/voice-gateway.service/${name}";
  python = pkgs.python3.withPackages (ps: [
    ps.aiohttp
    ps.pyjwt
    ps.cryptography
  ]);
  gateway = pkgs.runCommand "voice-gateway" { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.aiohttp ps.pytest ps.pyjwt ps.cryptography ])) ]; } ''
    mkdir -p $out/bin $out/lib
    cp ${./gateway.py} $out/lib/gateway.py
    cp ${./test_gateway.py} test_gateway.py
    cp ${./gateway.py} gateway.py
    python -m pytest -q -p no:cacheprovider test_gateway.py
    cat > $out/bin/voice-gateway <<EOF
    #!${pkgs.runtimeShell}
    exec ${python}/bin/python3 $out/lib/gateway.py "\$@"
    EOF
    chmod +x $out/bin/voice-gateway
  '';

  settings = {
    stateDir = "/var/lib/voice-gateway";
    publicUrl = "https://${cfg.publicHost}";
    allowedDevices = cfg.satelliteDevices;
    idleMinutes = cfg.idleMinutes;
    unlockPhrases = [
      "unlock"
      "trusted mode"
      "trusted mode on"
      "entsperren"
      "trusted modus"
      "trusted modus an"
    ];
    # Fallback only while the infra agent is unreachable; normally the
    # agents end trusted mode through the MCP tool.
    offPhrases = [
      "trusted mode off"
      "lock"
      "trusted modus aus"
    ];
    unlockTtl = 120;
    unlockRate = [
      3
      600
    ];
    replyTimeout = 40;
    voiceCode = {
      seedFile = cred "voice-code";
      maxUses = 5;
      maxFails = 2;
      challengeTtl = 30;
      startPhrases = [ cfg.startPhrase ] ++ cfg.extraStartPhrases;
    };
    agents = {
      voice = {
        url = "http://127.0.0.1:${toString apiPort}";
        keyFile = cred "voice-api-key";
        session = "voice";
      }
      // lib.optionalAttrs (cfg.voiceModel != null) { inherit (cfg.voiceModel) provider model; };
      infra = {
        url = "http://${infraGuest}:${toString voiceApiPort}";
        keyFile = cred "infra-api-key";
        session = "voice";
      };
    };
    ntfy = {
      url = "https://${cfg.ntfyHost}";
      topic = "voice-unlock";
      tokenFile = cred "ntfy-token";
    };
    ha = {
      url = "http://cm-pi.d:8123";
      satellite = cfg.satelliteEntity;
      tokenFile = cred "ha-token";
    };
    oidc = {
      inherit (config.hyper.oidc) issuer;
      clientId = "voice";
      secretFile = cred "oidc-secret";
      user = "dave";
      group = "voice";
      maxAuthAge = 60;
    };
    haSecretFile = cred "ha-secret";
    mcpTokens = {
      voice = cred "mcp-voice";
      infra = cred "mcp-infra";
    };
    listen = {
      ha = [ [ somYgg cfg.haPort ] ];
      web = [ [ somYgg cfg.webPort ] ];
      mcp = [
        [ "127.0.0.1" cfg.mcpPort ]
        [ vethHost cfg.mcpPort ]
      ];
    };
  };
  hex = n: ''
    openssl rand -hex ${toString n} | tr -d '\n' > "$out"/key
  '';
  keyGen = n: {
    files.key = { };
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    script = hex n;
  };
in
{
  imports = [ ./shared-vars.nix ];

  options.hyper.voiceGateway = {
    enable = lib.mkEnableOption "the Voice PE -> hermes router";
    publicHost = lib.mkOption {
      type = lib.types.str;
      default = "voice.davhau.com";
      description = "The unlock app's public name (edi's nginx -> webPort here).";
    };
    ntfyHost = lib.mkOption {
      type = lib.types.str;
      default = "ntfy.davhau.com";
    };
    satelliteDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "HA device ids that may unlock (trusted mode binds to the one that asked).";
    };
    satelliteEntity = lib.mkOption {
      type = lib.types.str;
      description = "assist_satellite entity for announcements.";
    };
    idleMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Trusted mode ends after this long without a request from the bound satellite.";
    };
    startPhrase = lib.mkOption {
      type = lib.types.str;
      default = "what's on the list";
      description = "Starts the voice-code challenge (matched loosely, case-insensitive).";
    };
    extraStartPhrases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "was steht auf der liste" ];
    };
    voiceModel = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      # null: the voice agent's own model, p0's Qwen (thinking off there).
      default = null;
      example = {
        provider = "anthropic";
        model = "claude-sonnet-5-5";
      };
      description = "Model the voice agent answers with, per request (null: the agent's own model, p0's Qwen).";
    };
    haPort = lib.mkOption {
      type = lib.types.port;
      default = 8651;
    };
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 8652;
    };
    mcpPort = lib.mkOption {
      type = lib.types.port;
      default = 8653;
    };
  };

  config = lib.mkIf cfg.enable {
    clan.core.vars.generators = {
      voice-unlock-code = {
        files.code = { };
        runtimeInputs = [ pkgs.python3 ];
        script = ''
          python3 -c 'import secrets; print("".join(str(secrets.randbelow(10)) for _ in range(6)), end="")' > "$out"/code
        '';
      };
      voice-api-key = keyGen 32 // {
        files.key.restartUnits = [ "hermes-agent-voice.service" ];
      };
      voice-infra-api-key = keyGen 32 // {
        files.key.restartUnits = [ "container@infra-space.service" ];
      };
      voice-mcp-voice = keyGen 32 // {
        files.key.restartUnits = [ "hermes-agent-voice.service" ];
      };
      voice-mcp-infra = keyGen 32 // {
        files.key.restartUnits = [ "container@infra-space.service" ];
      };
      # Long-lived HA tokens of the non-admin HA users voice-gateway (the
      # announce) and voice-agent (the voice agent's MCP). Persisted
      # prompts: minted on cm-pi, stored with `clan vars set som <gen>/token`.
      voice-ha-announce-token = {
        prompts.token = {
          type = "hidden";
          persist = true;
          description = "HA long-lived token of the non-admin HA user voice-gateway (cm-pi), for assist_satellite.announce";
        };
        files.token.restartUnits = [ "voice-gateway.service" ];
      };
      voice-ha-mcp-token = {
        prompts.token = {
          type = "hidden";
          persist = true;
          description = "HA long-lived token of the non-admin HA user voice-agent (cm-pi), for the voice agent's MCP";
        };
        files.token.restartUnits = [ "hermes-agent-voice.service" ];
      };
      voice-gateway-ha.files.secret.restartUnits = [ "voice-gateway.service" ];
      voice-ntfy.files.publisher-token.restartUnits = [ "voice-gateway.service" ];
    };

    users.users.${user} = {
      isSystemUser = true;
      inherit uid;
      group = user;
    };
    users.groups.${user}.gid = uid;

    systemd.services.voice-gateway = {
      description = "Voice PE -> hermes router (trusted mode, unlock)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${gateway}/bin/voice-gateway ${pkgs.writeText "voice-gateway.json" (builtins.toJSON settings)}";
        User = user;
        Group = user;
        StateDirectory = "voice-gateway";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;
        LoadCredential = [
          "voice-code:${vars.voice-unlock-code.files.code.path}"
          "voice-api-key:${vars.voice-api-key.files.key.path}"
          "infra-api-key:${vars.voice-infra-api-key.files.key.path}"
          "mcp-voice:${vars.voice-mcp-voice.files.key.path}"
          "mcp-infra:${vars.voice-mcp-infra.files.key.path}"
          "ntfy-token:${vars.voice-ntfy.files.publisher-token.path}"
          "ha-token:${vars.voice-ha-announce-token.files.token.path}"
          "ha-secret:${vars.voice-gateway-ha.files.secret.path}"
          "oidc-secret:${config.hyper.oidc.clients.voice.secretFile}"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    # The voice agent's api_server (hermes' API_SERVER_* env, key as
    # secretEnv), behind core's owner-only forward; the MCP lock tool.
    services.hyperhermes.forwards.apiserver = {
      label = "API server";
      portFor = _: apiPort;
      backendBase = apiBackendBase;
      enabledFor = u: u == "voice";
    };
    services.hyperhermes.agents.voice = {
      environment = {
        API_SERVER_HOST = "127.0.0.1";
        API_SERVER_PORT = toString (apiBackendBase + voiceUid);
        API_SERVER_MODEL_NAME = "voice";
      };
      secretEnv = {
        API_SERVER_KEY = vars.voice-api-key.files.key.path;
        VOICE_MCP_TOKEN = vars.voice-mcp-voice.files.key.path;
        HA_TOKEN = vars.voice-ha-mcp-token.files.token.path;
      };
      settings.mcp_servers = {
        voice-gateway = {
          url = "http://127.0.0.1:${toString cfg.mcpPort}/mcp";
          headers.Authorization = "Bearer \${VOICE_MCP_TOKEN}";
        };
        # Home Assistant's MCP server (Assist API: exposed entities only) as
        # the non-admin HA user voice-agent, as roman's agent does
        # (../../../machines/som/roman-home-assistant.nix).
        home-assistant = {
          url = "http://cm-pi.d:8123/api/mcp";
          headers.Authorization = "Bearer \${HA_TOKEN}";
        };
      };
    };
    systemd.services.hermes-firewall.script = lib.mkAfter ''
      iptables -w -I ${hlib.chain} 1 -p tcp --dport ${toString apiPort} -m owner --uid-owner ${user} -j RETURN
    '';

    # The infra agent's api_server and MCP token (../infra-space/voice-api.nix).
    hyper.infraSpace.credentials = {
      voice-api-key = vars.voice-infra-api-key.files.key.path;
      voice-mcp-token = vars.voice-mcp-infra.files.key.path;
    };
    hyper.infraSpace.guestModules = [
      {
        imports = [ ../infra-space/voice-api.nix ];
        infraSpace.voiceApi = {
          enable = true;
          listenAddress = infraGuest;
          port = voiceApiPort;
          mcpUrl = "http://${vethHost}:${toString cfg.mcpPort}/mcp";
        };
      }
    ];
    hyper.infraSpace.extraToGuestRules = [
      "meta skuid ${toString uid} tcp dport ${toString voiceApiPort} return"
    ];

    networking.firewall.extraInputRules = ''
      iifname "ygg" ip6 saddr ${cmPiYgg} tcp dport ${toString cfg.haPort} accept
      iifname "ygg" ip6 saddr ${ediYgg} tcp dport ${toString cfg.webPort} accept
    '';
    networking.firewall.interfaces."ve-infra-space".allowedTCPPorts = [ cfg.mcpPort ];

    # Local users other than root never open the ygg listeners (they would
    # arrive through lo, which the input rules above do not cover).
    networking.nftables.tables.voice-gateway = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ip6 daddr ${somYgg} tcp dport { ${toString cfg.haPort}, ${toString cfg.webPort} } ct state new meta skuid != 0 reject with tcp reset
        }
      '';
    };
  };
}
