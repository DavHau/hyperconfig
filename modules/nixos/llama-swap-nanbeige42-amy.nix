# Nanbeige4.2-3B (dense looped transformer, 3B non-embedding params,
# 256K native ctx) + DSpark speculative decoding for llama-swap on amy
# (Framework 13, Ryzen AI 9 HX 370, Radeon 890M iGPU, ~80 GiB unified
# RAM). Small agentic model: tops Artificial Analysis' small-model
# board; model card claims SWE-Bench Verified 63.6 / Terminal-Bench 2.0
# 44.1 -- above Qwen3.5-9B -- with thinking on.
#
#   - Quant: bartowski imatrix IQ4_XS (2.44 GB). No unsloth UD quant
#     exists for this model; imatrix IQ4_XS is the same 4.25 bpw
#     non-linear quant family as the UD-IQ4_XS used for qwen3.6 here,
#     minus unsloth's per-layer bit mixing (irrelevant at 2.4 GB).
#     mradermacher's i1-IQ4_XS is the alternative if this one misbehaves.
#   - Speculative decode: no MTP head in this model; Nanbeige ships a
#     separate DSpark draft (DFlash block-diffusion backbone + Markov
#     head, Qwen3 backbone, block size 7) -- the same lever as the MTP
#     GGUFs on qwen3.6, just as a sidecar file. Draft GGUF from
#     SUPEROXIDES (mainline b10729 conversion, Q8_0, 0.9 GB; the draft
#     reads the target's per-layer hidden states, so it stays at 8-bit
#     to keep the acceptance rate up). `--spec-draft-n-max 7` = trained
#     block size (clamped there anyway).
#     Measured on amy (2026-09-10, 600-token thinking gen, greedy):
#     14 t/s plain -> 24 t/s with DSpark (1.7x), ~45% draft acceptance.
#   - Engine: pinned to inputs.nixpkgs-llama-cpp (v0.4.0 = b10809), NOT
#     the fleet pkgs.llama-cpp (b10408). The nanbeige graph only exports
#     per-layer inputs for DFlash/DSpark drafts since b10644
#     (ggml-org/llama.cpp#27730); on b10408 the model loads but the
#     draft has nothing to condition on. Vulkan build as in
#     llama-swap-qwen36-amy.nix (RADV drives the 890M well; no ROCm
#     gfx1150 support matrix games).
#   - KV: 22 layers x 8 KV heads x 128 dim, GQA. ~44 KiB/token at q8_0
#     (~88 KiB if llama.cpp keeps separate KV per loop iteration --
#     unverified). 128K ctx = 5.5-11 GiB; kept at 128K instead of the
#     native 256K so RAM stays free for the agent VMs. Bump -c to
#     262144 if a long-context job needs it.
#   - Sampling: model card recommends temp 1.0 for agentic/tool-use
#     and 0.6 for reasoning/chat, top_p 0.95, top_k 20 (generate()
#     example). Agentic profile chosen: this is the hermes brain
#     candidate, not a chat model.
#   - Chat template: ChatML with <think>; thinking on by default,
#     tool calls in xml (recommended) or json. --jinja uses the
#     GGUF-embedded template; llama-server's default reasoning-format
#     (auto) already splits <think> into reasoning_content.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.llama-swap;

  # See llama-swap-qwen36.nix: HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  iq4xs = pkgs.fetchurl {
    url = "https://huggingface.co/bartowski/Nanbeige_Nanbeige4.2-3B-GGUF/resolve/main/Nanbeige_Nanbeige4.2-3B-IQ4_XS.gguf";
    hash = "sha256-96Wyd1n9LyYkaXsZ/cC4chM2mFKa2akmsS/lb2JQ/vw=";
    curlOptsList = bigFetchCurlOpts;
  };

  dspark = pkgs.fetchurl {
    url = "https://huggingface.co/SUPEROXIDES/NANBEIGE4.2_3B_DSPARK_-_GGUF/resolve/main/dspark-Nanbeige4.2-Nanbeige4.X-3B-Q8_0.gguf";
    hash = "sha256-G3JN7d2N2LW2Cfh+9paq8n2BH6nihUk36FejdUNx9Xw=";
    curlOptsList = bigFetchCurlOpts;
  };

  llama-cpp-vulkan =
    inputs.nixpkgs-llama-cpp.legacyPackages.${pkgs.stdenv.hostPlatform.system}.llama-cpp.override {
      vulkanSupport = true;
      cudaSupport = false;
      rocmSupport = false;
    };
in
{
  services.llama-swap.settings.models = {
    "nanbeige4.2:3b-iq4_xs".cmd = lib.concatStringsSep " " [
      (lib.getExe' llama-cpp-vulkan "llama-server")
      "-m ${iq4xs}"
      "--port \${PORT}"
      "--jinja"
      "-c 131072"
      "-fa on"
      "--cache-type-k q8_0"
      "--cache-type-v q8_0"
      "-ngl 99"
      # DSpark block-parallel speculative decode via the sidecar draft.
      "-md ${dspark}"
      "-ngld 99"
      "--spec-type draft-dspark"
      "--spec-draft-n-max 7"
      # Agentic/tool-use sampling per model card.
      "--temp 1.0"
      "--top-p 0.95"
      "--top-k 20"
      "--min-p 0.0"
    ];
  };
}
