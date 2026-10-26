# Document OCR for the hermes agents on som: Typhoon OCR 1.5 2B
# (typhoon-ai/typhoon-ocr1.5-2b, Qwen3-VL-2B fine-tuned for Thai and
# English documents, Apache-2.0) on llama-server, behind ./parse.py, a
# Firecrawl-Parse-compatible endpoint (POST /v2/parse). hermes' read_file
# sends scanned PDFs there (file_tools.hosted_ocr_url, see
# ../hermes-browser/ocr.nix); the agents' `ocr` CLI uses it for images and
# page ranges. Why this model: the best open Thai OCR by a wide margin
# (median page CER 0.21% on printed Thai vs 6.64% for PaddleOCR-VL-1.6,
# arXiv:2609.03595 Table 7), 2B so it fits beside CaptchaKraken, and
# Qwen3-VL, which llama.cpp supports natively.
#
# On demand, like ../captchakraken-server.nix: the first connection to
# [vit ygg]:8098 starts parse.py and llama-server (5 s with the GGUFs in
# page cache, ~6 GB VRAM), and both stop after `idle` without a
# connection, freeing the card. Reachable from som's yggdrasil address
# only; parse.py and llama-server listen on loopback and talk to nothing
# else. Documents never leave vit.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  port = 8098;
  parsePort = 8099;
  llamaPort = 8100;
  # A document is one burst of page requests; an agent reading several
  # files does so minutes apart at most. Past that, a 5 s reload is
  # cheaper than holding the VRAM away from captchakraken and GPU jobs.
  idle = "5min";
  # Pages transcribed concurrently: llama-server slots, and parse.py's
  # workers. Each slot holds one page image (~2.2k tokens at 1800 px),
  # the prompt and up to 8192 output tokens.
  slots = 2;

  vitYgg = config.clan.core.vars.generators.yggdrasil.files.address.value;
  somYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "som";
    generator = "yggdrasil";
    file = "address";
  };

  # Same import as ../captchakraken-server.nix, so llama-cpp comes from
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
      url = "https://huggingface.co/mradermacher/typhoon-ocr1.5-2b-GGUF/resolve/fb24f41dfe4358fea131d31b022dd0799eba15fa/${file}";
      inherit sha256;
    };
  # Q8_0 text model, F16 vision tower: on a scanned EN+Thai lab report it
  # transcribed the same text as the F16 model (1.2% CER, all from `<`
  # rendered as `&lt;` in tables) at 185 instead of 128 tok/s and 1.6 GB
  # less VRAM. The model card warns that GGUF builds can lose accuracy;
  # the vision projector, where quantization hurts most, stays F16.
  model = hf "typhoon-ocr1.5-2b.Q8_0.gguf" "32e7363f1f2a15864750d6feb2ed1b9fe54539c41d4ab9288dba88fa4ff0d7a4";
  mmproj = hf "typhoon-ocr1.5-2b.mmproj-f16.gguf" "9f01ef845947c4985bd58eab434651a6acc97301c33e1742c1a8f89230078d75";

  llamaUrl = "http://127.0.0.1:${toString llamaPort}";
  parseUrl = "http://127.0.0.1:${toString parsePort}";
  waitHealthy =
    url: "${lib.getExe pkgs.curl} -sf -o /dev/null --retry 300 --retry-delay 1 --retry-all-errors ${url}/health";

  hardening = {
    DynamicUser = true;
    PrivateTmp = true;
    PrivateUsers = true;
    PrivateMounts = true;
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
    RemoveIPC = true;
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
  };
in
{
  systemd.services.ocr-llama = {
    description = "Typhoon OCR llama-server (started by ocr-parse)";
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = hardening // {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe' pkgsCuda.llama-cpp "llama-server")
        "--model"
        model
        "--mmproj"
        mmproj
        "--host"
        "127.0.0.1"
        "--port"
        (toString llamaPort)
        "--parallel"
        (toString slots)
        "--ctx-size"
        (toString (slots * 12288))
        # Qwen3-VL's default pixel budget would shrink an 1800 px page.
        "--image-max-tokens"
        "4096"
        "--cache-ram"
        "0"
        "--no-webui"
        "--offline"
      ];
      # Active only once the model is loaded, so parse.py never sends into
      # a closed port.
      ExecStartPost = waitHealthy llamaUrl;
      TimeoutStartSec = 330;
      Restart = "on-failure";
      RestartSec = 10;
      MemoryDenyWriteExecute = true;
      PrivateDevices = false; # the GPU
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

  systemd.services.ocr-parse = {
    description = "Firecrawl-Parse-compatible OCR endpoint (started by ocr.socket)";
    requires = [ "ocr-llama.service" ];
    after = [ "ocr-llama.service" ];
    unitConfig.StopWhenUnneeded = true;
    path = [
      pkgs.poppler-utils
      pkgs.imagemagick
    ];
    environment = {
      OCR_PORT = toString parsePort;
      OCR_LLAMA_URL = llamaUrl;
      OCR_SLOTS = toString slots;
    };
    serviceConfig = hardening // {
      ExecStart = "${lib.getExe pkgs.python3} ${./parse.py}";
      ExecStartPost = waitHealthy parseUrl;
      Restart = "on-failure";
      RestartSec = 5;
      PrivateDevices = true;
      MemoryMax = "4G";
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";
    };
  };

  systemd.sockets.ocr = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "[${vitYgg}]:${toString port}" ];
    # The ygg address appears only once yggdrasil is up.
    socketConfig.FreeBind = true;
  };

  systemd.services.ocr = {
    description = "OCR endpoint for som (starts ocr-parse and the model on demand)";
    requires = [ "ocr-parse.service" ];
    after = [ "ocr-parse.service" ];
    serviceConfig = hardening // {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=${idle} 127.0.0.1:${toString parsePort}";
      PrivateDevices = true;
      MemoryDenyWriteExecute = true;
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
