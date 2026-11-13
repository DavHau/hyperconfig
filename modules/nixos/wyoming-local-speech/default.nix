# Local speech for Home Assistant (cm-pi) on vit: two Wyoming servers, Intel
# iGPU + CPU only. The NVIDIA card is never used: the units see no
# /dev/nvidia* (DevicePolicy closed, only char-drm), CUDA_VISIBLE_DEVICES is
# empty and the OpenCL loader only gets intel-neo.icd.
#
# - speech-stt (port 10300): ./stt.py. One Whisper large-v3-turbo int8
#   encoder pass on the iGPU (OpenVINO) per utterance; the first decoder step
#   gives the language logits, softmax over en/de/th only. P(th) >=
#   thaiThreshold -> Pathumma Thai FastConformer-RNNT (ONNX, OpenVINO CPU);
#   else the same encoder output is decoded by Whisper (greedy) in en or de.
#   HA's requested language is ignored.
# - speech-tts (port 10200): ./tts.py, CPU only, 4 threads per engine:
#   Kokoro-82M int8 (en, kokoro-onnx), Supertonic 3 (de, 8 steps), Wayu
#   Kokoro-Thai fp32 ONNX (th). Language from the reply text; voice per
#   language from ${state}/tts-voices.json (re-read on mtime change),
#   written only by tts.py's HTTP API (apiPort: GET/PUT /voices, POST
#   /preview, GET / = voice-picker page) on localhost, and for edi's
#   pocket-id-protected proxy (./voices-sso.nix, voices.davhau.com).
#   Drop-in voices: ${state}/voices.d/<engine>/ (group speech-voices,
#   setgid, see ./voices.d-README.md), rescanned live.
#
# Python: no nixpkgs set has openvino/supertonic/kokoro-onnx, so
# speech-setup builds a uv venv over nixpkgs' python312 from the hashed
# ./requirements.txt (locked from ./requirements.in, command in its header;
# tltk --no-deps from ./requirements-nodeps.txt)
# and downloads the models with snapshot_download(local_dir=...) at pinned
# revisions into /var/lib/speech/models (onnxruntime >= 1.31 rejects the HF
# cache's symlinked external data). Pathumma has no ONNX on the hub: its
# NeMo->ONNX export (encoder-model.onnx, decoder_joint-model.onnx, info.json,
# vocab.json) is copied once from `pathummaOnnxSource` (dave-hermes's
# speechbench export) into models/pathumma-onnx. Each model has its own
# OpenVINO CACHE_DIR: a shared one produced silent garbage transcripts.
# The iGPU decoder compile itself is also flaky (some compiles loop on a
# token); stt.py checks it against the CPU decoder on checkClipSource at
# every start and recompiles until they match.
#
# Prototype and benchmarks: vit:/home/dave-hermes/jobs/speechbench.
# Reachable from cm-pi's yggdrasil address only (HA adds them as vit.d).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.wyomingLocalSpeech;
  state = "/var/lib/speech";
  # speech-stt writes the language of the latest utterance; speech-tts uses
  # it to break en/de ties in the reply text (tts.py guess_lang).
  lastLangFile = "${state}/last-utterance-lang";
  models = "${state}/models";
  venv = "${state}/venv";
  python = pkgs.python312;

  cmPiYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "cm-pi";
    generator = "yggdrasil";
    file = "address";
  };

  # [repo, revision, dir, allow_patterns (null = all)]
  hfModels = [
    [ "OpenVINO/whisper-large-v3-turbo-int8-ov" "b568445dd5dc8c695bde596f8acbb4694fd6ba64" "whisper-large-v3-turbo-int8-ov" null ]
    [ "Supertone/supertonic-3" "724fb5abbf5502583fb520898d45929e62f02c0b" "supertonic-3" null ]
    # kokoro_thai package + fp32 ONNX graphs; not the .pth/.pt training files.
    [ "kunato/wayu-kokoro-thai-v1" "abf63dc118365bea784fa881bdd1dce4b2cc1fd4" "wayu-kokoro-thai-v1" [ "kokoro_thai/*" "onnx/*" "data/seeds/roster.json" "assets/*" "README.md" ] ]
  ];

  # Kokoro-82M from kokoro-onnx's release model-files-v1.0.
  kokoroRel = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0";
  kokoroModel = pkgs.fetchurl {
    url = "${kokoroRel}/kokoro-v1.0.int8.onnx";
    hash = "sha256-bnQhcNMJAW5YkamU4c4VWccCoszQB15n73FXl09kBss=";
  };
  kokoroVoices = pkgs.fetchurl {
    url = "${kokoroRel}/voices-v1.0.bin";
    hash = "sha256-vKYQuDCOjZnzLm/kGX5+wBZ5Jk7+0MrJFA/pwp8fv30=";
  };
  voicesDir = "${state}/voices.d";
  selectionFile = "${state}/tts-voices.json";
  # The voice-picker's SSO proxy (./voices-sso.nix).
  ediYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "edi";
    generator = "yggdrasil";
    file = "address";
  };

  # Wheels' native libs (libstdc++, zlib) and libOpenCL (ocl-icd).
  libPath = "${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ]}:/run/current-system/sw/lib";
  oclVendors = pkgs.runCommand "ocl-vendors-intel-only" { } ''
    mkdir -p $out
    cp ${pkgs.intel-compute-runtime}/etc/OpenCL/vendors/intel-neo.icd $out/
  '';

  importLocal = pkgs.writeShellScript "speech-import-local" ''
    set -eu
    install -d -o speech -g speech ${models}
    p=${models}/pathumma-onnx
    if [ ! -s $p/decoder_joint-model.onnx ]; then
      rm -rf $p.tmp; mkdir $p.tmp
      cp ${cfg.pathummaOnnxSource}/{encoder-model.onnx,decoder_joint-model.onnx,info.json,vocab.json} $p.tmp/
      chown -R speech:speech $p.tmp; mv $p.tmp $p
    fi
    if [ ! -s ${checkClip} ]; then
      install -o speech -g speech -m 644 ${cfg.checkClipSource} ${checkClip}
    fi
    # Drop-in voices: group-writable for speech-voices members, setgid.
    install -d -o speech -g speech-voices -m 2775 ${voicesDir}
    for e in kokoro82 supertonic wayu_thai; do
      install -d -o speech -g speech-voices -m 2775 ${voicesDir}/$e
    done
    install -o speech -g speech-voices -m 644 ${./voices.d-README.md} ${voicesDir}/README.md
  '';
  checkClip = "${models}/check-de.wav";

  env = {
    HOME = state;
    HF_HOME = "${state}/hf";
    HF_HUB_OFFLINE = "1";
    PYTHAINLP_DATA = "${state}/pythainlp-data";
    PYTHONDONTWRITEBYTECODE = "1";
    LD_LIBRARY_PATH = libPath;
    OCL_ICD_VENDORS = "${oclVendors}";
    CUDA_VISIBLE_DEVICES = "";
    NEOReadDebugKeys = "0";
  };

  hardening = {
    User = "speech";
    Group = "speech";
    ProtectSystem = "strict";
    ReadWritePaths = [ state ];
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = [ "" ];
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
    # Intel iGPU render node only (PCI 00:02.0); no /dev/nvidia*, not the
    # NVIDIA card's DRM nodes.
    DevicePolicy = "closed";
    DeviceAllow = [ "/dev/dri/by-path/pci-0000:00:02.0-render rw" ];
  };

  server =
    name: description: args: memMax:
    {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      requires = [ "speech-setup.service" ];
      after = [ "speech-setup.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = env;
      serviceConfig = hardening // {
        ExecStart = "${venv}/bin/python ${./.}/${name}.py ${lib.escapeShellArgs args}";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStartSec = 300;
        MemoryMax = memMax;
        IPAddressDeny = "any";
        IPAddressAllow = [ cmPiYgg "localhost" ];
      };
    };
in
{
  options.hyper.wyomingLocalSpeech = {
    enable = lib.mkEnableOption "local Wyoming STT/TTS for Home Assistant";
    thaiThreshold = lib.mkOption {
      type = lib.types.str;
      default = "0.03";
      description = ''
        Route an utterance to Pathumma when P(th) >= this, P being Whisper's
        language softmax over en/de/th only. Not argmax: Whisper labels
        short Thai clips as English (Dave's value).
      '';
    };
    sttPort = lib.mkOption { type = lib.types.port; default = 10300; };
    ttsPort = lib.mkOption { type = lib.types.port; default = 10200; };
    apiPort = lib.mkOption {
      type = lib.types.port;
      default = 10201;
      description = "tts.py's HTTP voice API + picker page: localhost, and edi's SSO proxy over yggdrasil.";
    };
    ttsMemoryMax = lib.mkOption { type = lib.types.str; default = "4G"; };
    translatePort = lib.mkOption {
      type = lib.types.port;
      default = 10202;
      description = "translate.py (loopback): the picker's sample sentence into en/de/th via p0's Qwen.";
    };
    pathummaOnnxSource = lib.mkOption {
      type = lib.types.str;
      default = "/home/dave-hermes/jobs/speechbench/models/pathumma/onnx";
      description = "NeMo->ONNX export of nectec/Pathumma-stt-th-fastconformer-rnnt-large, copied once.";
    };
    checkClipSource = lib.mkOption {
      type = lib.types.str;
      default = "/home/dave-hermes/jobs/speechbench/stt/de_001.wav";
      description = ''
        16 kHz German clip (FLEURS) for stt.py's startup decoder self-check
        (catches bad iGPU compiles, see Whisper.self_check), copied once.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.speech = {
      isSystemUser = true;
      group = "speech";
      extraGroups = [ "render" "video" ];
      home = state;
    };
    users.groups.speech = { };
    # May add drop-in voices to voices.d (nothing else of the state dir).
    users.groups.speech-voices.members = [ "dave-hermes" ];
    # 0751: speech-voices members traverse to voices.d, list nothing else.
    systemd.tmpfiles.rules = [ "d ${state} 0751 speech speech -" ];

    systemd.services.speech-setup = {
      description = "Speech: python venv and models";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = env // {
        HF_HUB_OFFLINE = "0";
        UV_CACHE_DIR = "${state}/uv-cache";
        UV_PYTHON_DOWNLOADS = "never";
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "30min";
        # Root (+): the one-time copies read dave-hermes's 0700 home.
        ExecStartPre = "+${importLocal}";
        DeviceAllow = [ ];
      };
      script = ''
        set -eu
        stamp="${python} ${./requirements.txt} ${./requirements-nodeps.txt}"
        if [ "$(cat ${venv}/.stamp 2>/dev/null || true)" != "$stamp" ]; then
          rm -rf ${venv}
          ${lib.getExe pkgs.uv} venv -q -p ${python}/bin/python3 ${venv}
          ${lib.getExe pkgs.uv} pip install -q -p ${venv}/bin/python --require-hashes -r ${./requirements.txt}
          ${lib.getExe pkgs.uv} pip install -q -p ${venv}/bin/python --require-hashes --no-deps -r ${./requirements-nodeps.txt}
          printf '%s' "$stamp" > ${venv}/.stamp
        fi
        ${venv}/bin/python - <<'EOF'
        import json, os
        from huggingface_hub import snapshot_download
        for repo, rev, d, pat in json.loads(${builtins.toJSON (builtins.toJSON hfModels)}):
            p = "${models}/" + d
            if os.path.exists(p + "/.rev") and open(p + "/.rev").read() == rev:
                continue
            snapshot_download(repo, revision=rev, local_dir=p, allow_patterns=pat)
            open(p + "/.rev", "w").write(rev)
        EOF
        rm -rf ${models}/kokoro-thai-q8-onnx
        mkdir -p ${state}/ov-cache/whisper ${state}/ov-cache/pathumma
      '';
    };

    systemd.services.speech-stt = server "stt" "Wyoming STT: Whisper (Intel iGPU) + Pathumma Thai (CPU)" [
      "--uri" "tcp://[::]:${toString cfg.sttPort}"
      "--whisper-dir" "${models}/whisper-large-v3-turbo-int8-ov"
      "--whisper-cache" "${state}/ov-cache/whisper"
      "--whisper-device" "GPU"
      "--check-clip" checkClip
      "--pathumma-dir" "${models}/pathumma-onnx"
      "--pathumma-cache" "${state}/ov-cache/pathumma"
      "--pathumma-threads" "8"
      "--th-threshold" cfg.thaiThreshold
      "--last-lang-file" lastLangFile
    ] "5G";

    systemd.services.speech-tts = lib.recursiveUpdate (server "tts" "Wyoming TTS: Kokoro-82M (en), Supertonic 3 (de), Wayu Kokoro-Thai (th), CPU" [
      "--uri" "tcp://[::]:${toString cfg.ttsPort}"
      "--api-host" "127.0.0.1"
      "--api-host" "::"
      "--api-port" (toString cfg.apiPort)
      "--supertonic-dir" "${models}/supertonic-3"
      "--kokoro-model" "${kokoroModel}"
      "--kokoro-voices" "${kokoroVoices}"
      "--wayu-dir" "${models}/wayu-kokoro-thai-v1"
      "--voices-dir" voicesDir
      "--selection-file" selectionFile
      "--threads" "4"
      "--steps" "8"
      "--translate-url" "http://127.0.0.1:${toString cfg.translatePort}"
      "--last-lang-file" lastLangFile
    ] cfg.ttsMemoryMax) {
      serviceConfig = {
        SupplementaryGroups = [ "speech-voices" ];
        IPAddressAllow = [ cmPiYgg "localhost" ediYgg ];
      };
      environment.NLTK_DATA = "${state}/nltk-data";
    };

    # The picker's translator: p0's Qwen over the internet with the fleet
    # inference key, so outside speech-tts' IP sandbox. Loopback only.
    hyper.inferenceApiKey.users = [ "speech" ];
    systemd.services.speech-translate = {
      description = "Voice picker: sample sentence -> en/de/th (p0 Qwen)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "speech-setup.service" ];
      after = [ "speech-setup.service" "network-online.target" "inference-api-key-speech.service" ];
      wants = [ "network-online.target" "inference-api-key-speech.service" ];
      serviceConfig = {
        User = "speech";
        Group = "speech";
        ExecStart = "${venv}/bin/python ${./.}/translate.py ${lib.escapeShellArgs [
          "--port" (toString cfg.translatePort)
          "--base-url" "https://inference.p0.contact/v1"
          "--model" "qwen"
          "--key-file" (config.hyper.inferenceApiKey.userTokenPath "speech")
        ]}";
        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "256M";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    networking.firewall.extraInputRules = ''
      iifname "ygg" ip6 saddr ${cmPiYgg} tcp dport { ${toString cfg.sttPort}, ${toString cfg.ttsPort} } accept
      iifname "ygg" ip6 saddr ${ediYgg} tcp dport ${toString cfg.apiPort} accept
    '';
  };
}
