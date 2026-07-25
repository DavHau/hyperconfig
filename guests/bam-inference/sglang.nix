# KEPT FOR REFERENCE — NOT IMPORTED. SGLang cannot load this checkpoint:
# it is NVFP4A16 (compressed-tensors "nvfp4-pack-quantized", 4-bit float
# weights, FP16 activations) and SGLang (incl. master as of 2026-07-25)
# has no W4A16-NVFP4 scheme: compressed_tensors scheme detection falls
# through to _is_static_tensor_w8a8 and crashes on input_quant=None
# (AttributeError: 'NoneType' object has no attribute 'num_bits').
# Verified crashing on v0.5.8.post1 and v0.5.16-cu130. vllm.nix replaced it.
{config, lib, ...}: {
  # 450W power cap, applied after persistenced holds the GPU.
  systemd.services.gpu-powercap = {
    wantedBy = ["multi-user.target"];
    after = ["nvidia-persistenced.service"];
    requires = ["nvidia-persistenced.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pm 1
      ${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pl 450
    '';
  };

  hardware.nvidia-container-toolkit.enable = true;
  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = "podman";
    containers.sglang = {
      image = "docker.io/lmsysorg/sglang:v0.5.16-cu130";
      autoStart = true;
      extraOptions = [
        "--device=nvidia.com/gpu=all"
        "--network=host"
        # host IPC: container shares the guest's /dev/shm (~54G on 108G
        # RAM); --shm-size is rejected together with --ipc=host by podman.
        "--ipc=host"
      ];
      volumes = ["/var/lib/models:/models"];
      cmd = [
        "python3" "-m" "sglang.launch_server"
        "--model-path" "/models/m51Lab-MiniMax-M2.7-REAP-139B-A10B-NVFP4"
        "--host" "0.0.0.0"
        "--port" "30000"
        "--trust-remote-code"
        "--tp" "1"
        "--kv-cache-dtype" "fp8_e5m2"
        "--mem-fraction-static" "0.92"
        "--max-running-requests" "4"
        "--chunked-prefill-size" "8192"
        "--context-length" "131072"
        "--enable-hierarchical-cache"
        # gigabytes ("size of host KV cache memory pool in gigabytes",
        # sglang v0.5.8.post1 server_args.py)
        "--hicache-size" "64"
      ];
    };
  };
  # Supervision: oci-containers generates podman-sglang.service; harden it.
  systemd.services.podman-sglang = {
    after = ["gpu-powercap.service"];
    requires = ["gpu-powercap.service"];
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 10;
    };
  };
  systemd.tmpfiles.rules = ["d /var/lib/models 0755 root root -"];
  networking.firewall.allowedTCPPorts = [30000];
}
