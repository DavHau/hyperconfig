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
# - speech-tts (port 10200): ./tts.py. Supertonic 3 (en/de, built-in
#   voices M1..M5/F1..F5, 8 steps) and Kokoro-Thai Q8 ONNX (voice thai_som,
#   FastThaiG2P frontend), 8 CPU threads per engine.
#
# Python: no nixpkgs set has openvino/supertonic/fastthaig2p, so
# speech-setup builds a uv venv over nixpkgs' python312 from the hashed
# ./requirements.txt (locked from ./requirements.in, command in its header)
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
  models = "${state}/models";
  venv = "${state}/venv";
  python = pkgs.python312;

  cmPiYgg = inputs.clan-core.clanLib.getPublicValue {
    flake = config.clan.core.settings.directory;
    machine = "cm-pi";
    generator = "yggdrasil";
    file = "address";
  };

  # [repo, revision, dir]
  hfModels = [
    [ "OpenVINO/whisper-large-v3-turbo-int8-ov" "b568445dd5dc8c695bde596f8acbb4694fd6ba64" "whisper-large-v3-turbo-int8-ov" ]
    [ "Supertone/supertonic-3" "724fb5abbf5502583fb520898d45929e62f02c0b" "supertonic-3" ]
    [ "Rotem12/kokoro-thai-q8-onnx" "fb9070ec1f4dae354d2b83b1fe23e151ddd2cd5b" "kokoro-thai-q8-onnx" ]
  ];

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
    systemd.tmpfiles.rules = [ "d ${state} 0750 speech speech -" ];

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
        stamp="${python} ${./requirements.txt}"
        if [ "$(cat ${venv}/.stamp 2>/dev/null || true)" != "$stamp" ]; then
          rm -rf ${venv}
          ${lib.getExe pkgs.uv} venv -q -p ${python}/bin/python3 ${venv}
          ${lib.getExe pkgs.uv} pip install -q -p ${venv}/bin/python --require-hashes -r ${./requirements.txt}
          printf '%s' "$stamp" > ${venv}/.stamp
        fi
        ${venv}/bin/python - <<'EOF'
        import os
        from huggingface_hub import snapshot_download
        for repo, rev, d in ${builtins.toJSON hfModels}:
            p = "${models}/" + d
            if os.path.exists(p + "/.rev") and open(p + "/.rev").read() == rev:
                continue
            snapshot_download(repo, revision=rev, local_dir=p)
            open(p + "/.rev", "w").write(rev)
        EOF
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
    ] "4G";

    systemd.services.speech-tts = server "tts" "Wyoming TTS: Supertonic 3 (en/de) + Kokoro-Thai (th), CPU" [
      "--uri" "tcp://[::]:${toString cfg.ttsPort}"
      "--supertonic-dir" "${models}/supertonic-3"
      "--kokoro-dir" "${models}/kokoro-thai-q8-onnx"
      "--threads" "8"
      "--steps" "8"
    ] "4G";

    networking.firewall.extraInputRules = ''
      iifname "ygg" ip6 saddr ${cmPiYgg} tcp dport { ${toString cfg.sttPort}, ${toString cfg.ttsPort} } accept
    '';
  };
}
