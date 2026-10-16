# CaptchaKraken v1.2 (Qwen3.5-9B captcha merge, GGUF Q8_0 + F16 vision
# projector) on llama-server, for web-bench's camoufox-captchakraken setup
# on som (tools/web-bench).
#
# Socket-activated so the card stays free for the agents' GPU jobs: the
# first request to [vit ygg]:8096 starts llama-server (~12 GB VRAM, fewer
# GPU layers if a job holds memory: --fit is on), and it unloads after
# `idle` without a connection. Reachable from som's yggdrasil address only;
# llama-server itself listens on loopback and has no other network.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  port = 8096;
  backendPort = 8097;
  # One solve is a burst of requests seconds apart, and a cold start costs
  # 5-20 s of model load (5 s on an idle card, 17 s with a GPU job holding
  # memory, both with the GGUFs in page cache; more after a reboot).
  # Three idle minutes cover the gaps within a solve and between an agent's
  # retries on one page; past that, a reload is cheaper than holding ~10 GB
  # of VRAM away from the agents' GPU jobs. When the proxy exits,
  # StopWhenUnneeded below stops llama-server too.
  idle = "3min";

  vitYgg = config.clan.core.vars.generators.yggdrasil.files.address.value;
  somYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "som";
    generator = "yggdrasil";
    file = "address";
  };

  # Same import as ./hermes-agents-gpu-host.nix, so llama-cpp comes from
  # cache.nixos-cuda.org instead of a local CUDA build.
  pkgsCuda = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (pkgs) overlays;
    config = pkgs.config // {
      allowUnfree = true;
      cudaSupport = true;
    };
  };

  hf =
    file: sha256:
    pkgs.fetchurl {
      url = "https://huggingface.co/CaptchaKraken/CaptchaKraken-v1.2-GGUF/resolve/695643a9f997e0ac2e99a84febdf249eb53d7d61/${file}";
      inherit sha256;
    };
  model = hf "CaptchaKraken-v1.2-Q8_0.gguf" "cbfcb18fb9d88a06ed45c33d0070e721286210cdf56184d104c3a767f1658a66";
  # The vision half; without it the model answers blind instead of failing.
  mmproj = hf "mmproj-F16.gguf" "642055c3e02ad042c4d52be1a4267400bf8d27a2481bd48265137dcfa3273e0d";

  backend = "127.0.0.1:${toString backendPort}";
in
{
  services.llama-cpp = {
    enable = true;
    package = pkgsCuda.llama-cpp;
    settings = {
      host = "127.0.0.1";
      port = backendPort;
      inherit model mmproj;
      # The client's CAPTCHA_LORA_NAME; a registered id, so it picks the
      # prompt generation and pixel budget of these weights.
      alias = "CaptchaKraken/CaptchaKraken-v1.2-GGUF";
      # Animated challenges send several stills in one request.
      ctx-size = 16384;
      parallel = 1;
      cache-ram = 0;
      no-webui = true;
      offline = true;
    };
  };

  systemd.services.llama-cpp = {
    wantedBy = lib.mkForce [ ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      # Active only once the model is loaded, so the proxy never forwards
      # into a closed port.
      ExecStartPost = "${lib.getExe pkgs.curl} -sf -o /dev/null --retry 300 --retry-delay 1 --retry-all-errors http://${backend}/health";
      TimeoutStartSec = 330;
      RestartSec = lib.mkForce 10;
      DevicePolicy = "closed";
      DeviceAllow = [
        "char-nvidiactl"
        "char-nvidia-caps"
        "char-nvidia-frontend"
        "char-nvidia-uvm"
      ];
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };
  };

  systemd.sockets.captchakraken = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "[${vitYgg}]:${toString port}" ];
    # The ygg address appears only once yggdrasil is up.
    socketConfig.FreeBind = true;
  };

  systemd.services.captchakraken = {
    description = "CaptchaKraken endpoint for som (starts llama-server on demand)";
    requires = [ "llama-cpp.service" ];
    after = [ "llama-cpp.service" ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${idle} ${backend}";
      DynamicUser = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateUsers = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      CapabilityBoundingSet = [ "" ];
      NoNewPrivileges = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
      # Applies to the inherited listening socket too.
      IPAddressDeny = "any";
      IPAddressAllow = [
        somYgg
        "localhost"
      ];
    };
  };

  networking.firewall.extraInputRules = ''
    iifname "ygg" ip6 saddr ${somYgg} tcp dport ${toString port} accept
  '';
}
