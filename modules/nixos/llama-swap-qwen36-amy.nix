# Qwen3.6-35B-A3B (unsloth dynamic quants, MTP variant) for llama-swap,
# tuned for amy: Framework 13, Ryzen AI 9 HX 370, Radeon 890M iGPU,
# ~80 GiB unified RAM. Counterpart of llama-swap-qwen36.nix (vit, dGPU).
#
#   - Same GGUFs as vit's module (identical url+hash => identical store
#     path, downloaded once per store): unsloth UD-IQ4_XS Dynamic 2.0
#     quant from the MTP repo (~17 GiB) + F16 vision projector.
#   - iGPU has no dedicated VRAM: weights live in GTT (system RAM), so
#     there is no VRAM budget to split against and no --n-cpu-moe; full
#     offload (-ngl 99) lets Vulkan run attention/FFN while the memory
#     bandwidth is shared either way. Only 3B of 35B params are active
#     per token (MoE, 256 experts top-8), so decode stays interactive.
#   - MTP GGUF: multi-token-prediction speculative decode, 1.4-2.2x
#     faster generation (llama.cpp merged MTP support; unsloth's MTP
#     quants are out of experimental).
#   - 200K context is cheap: only 10 of 40 layers are full attention
#     (rest Gated DeltaNet) -> ~2 GiB KV at 200K with q8_0.
#
# The distro llama-server on amy is the stock CPU-only pkgs.llama-cpp;
# this model gets its own Vulkan build (RADV drives the 890M well and
# needs no ROCm gfx1150 support matrix games).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;

  # See llama-swap-qwen36.nix: HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  hfRepo = "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/main";

  iq4xs = pkgs.fetchurl {
    url = "${hfRepo}/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
    hash = "sha256-3yengENbe0XCWXU2ES6jywkfhUTD0MMxjZ9CWLMfet8=";
    curlOptsList = bigFetchCurlOpts;
  };

  # Vision projector (Qwen3.6 is natively multimodal).
  mmproj = pkgs.fetchurl {
    url = "${hfRepo}/mmproj-F16.gguf";
    hash = "sha256-cfPLwffMDzDQnUHPqSTABggn68M78VrOfoZmHoVvAWA=";
  };

  llama-cpp-vulkan = pkgs.llama-cpp.override {
    vulkanSupport = true;
    cudaSupport = false;
    rocmSupport = false;
  };
in
{
  services.llama-swap.settings.models = {
    "qwen3.6:35b-iq4_xs" = {
      cmd = lib.concatStringsSep " " [
        (lib.getExe' llama-cpp-vulkan "llama-server")
        "-m ${iq4xs}"
        "--mmproj ${mmproj}"
        "--port \${PORT}"
        "--jinja"
        # 200K context; q8_0 KV halves the (already small) cache. If
        # long context degrades, switch to bf16 KV cache instead.
        "-c 204800"
        "--cache-type-k q8_0"
        "--cache-type-v q8_0"
        "-ngl 99"
        # MTP speculative decode (model's built-in MTP head as
        # self-speculative draft). --spec-type draft-mtp is REQUIRED to
        # activate the MTP tensors; draft-n-max 2 is unsloth's sweet
        # spot on most hardware (hardware-dependent -- try 1..6).
        "--spec-type draft-mtp"
        "--spec-draft-n-max 2"
        # Recommended thinking-mode sampling for general/agentic tasks.
        "--temp 1.0"
        "--top-p 0.95"
        "--top-k 20"
        "--min-p 0.0"
      ];
    };
  };
}
