# Ling-3.0-tiny (inclusionAI; hybrid-linear MoE, 7.9B total / 1.3B
# active, 24 layers = 18 KDA + 6 MLA, 128 experts top-8 + 1 shared,
# 128K released ctx) for llama-swap on amy (Framework 13, Ryzen AI 9
# HX 370, Radeon 890M iGPU, ~80 GiB unified RAM). Small agentic model:
# AA Intelligence Index 25 / Agentic Index 16 at 1.3B active.
#
#   - Quant: bloomer010 UD-Q4_K_XL (5.34 GB): Q4_K experts, Q8_0
#     attention / KDA / Q-LoRA projections, embeddings and output.
#     Chosen over bartowski IQ4_XS (4.39 GB): on a tiny MoE the
#     attention + shared paths are a small share of bytes but carry
#     most of the precision loss, so ~20% more bytes buys a lot.
#   - Speculative decode: none. NO MTP head in these weights
#     (num_nextn_predict_layers = 0, no mtp.* tensors in the
#     safetensors index; only Ling-3.0-flash ships NextN), no DSpark /
#     DFlash draft published. ngram-mod (model-free) measured on amy
#     2026-09-18, 800-token greedy gen: 47.8 t/s vs 46.3 t/s plain --
#     noise, so left off. Prompt ~90 t/s. Tool calls + reasoning split
#     verified through the patched parser (tool_calls populated,
#     reasoning_content separate).
#   - Engine: inputs.nixpkgs-llama-cpp (v0.4.1 = b10964) + two
#     unmerged llama.cpp PRs vendored under ./patches (both apply
#     cleanly on v0.4.1, not on v0.4.0 -- #28682 needs common/parsers/):
#       #28682 dedicated Ling 3.0 parser: the template pre-opens
#              <think>, so tool calls before </think> were classified
#              as reasoning_content and dropped (content="", no
#              tool_calls). Validated upstream with
#              --reasoning-format deepseek.
#       #28724 sanitize invalid UTF-8 at the token boundary: Ling emits
#              stray byte-level pieces that 500 the parse layer.
#     bailingmoe3 itself landed at b10470 (#26608); the fleet
#     pkgs.llama-cpp is b10408 and cannot load the GGUF at all.
#     Vulkan build as in llama-swap-qwen36-amy.nix.
#   - KV: only the 6 MLA layers cache anything (KDA is recurrent
#     state); MLA latent 512 + rope -> well under 1 GiB at 128K in
#     f16, so no q8_0 KV needed. 256K needs a YaRN override (factor
#     2, theta 6e6, orig 131072 per the SGLang recipe) -- not done.
#   - Sampling: model card temp 1.0, top_p 0.95, top_k 20 (same for
#     chat and agentic).
#   - Chat template: Bailing V3 (<role>…</role> / <|role_end|>);
#     thinking on by default, per-request off via
#     chat_template_kwargs.enable_thinking=false. --jinja uses the
#     GGUF-embedded template.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.llama-swap;

  # See llama-swap-qwen36.nix: HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  udq4kxl = pkgs.fetchurl {
    url = "https://huggingface.co/bloomer010/Ling-3.0-tiny-GGUF/resolve/main/Ling-3.0-tiny-UD-Q4_K_XL.gguf";
    hash = "sha256-f67kCRN5zhxkTgndiISKjwvDNIohbS7hyQpTiN5qWxM=";
    curlOptsList = bigFetchCurlOpts;
  };

  # nodejs_latest = 26.9.0 at the locked rev: not on cache.nixos.org and
  # its test suite fails in the local sandbox; the webui builds fine on
  # the cached LTS node. npmDepsHash is node-version independent.
  pkgsLlama = inputs.nixpkgs-llama-cpp.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  llama-cpp-ling =
    (pkgsLlama.llama-cpp.override {
      vulkanSupport = true;
      cudaSupport = false;
      rocmSupport = false;
      nodejs_latest = pkgsLlama.nodejs;
    }).overrideAttrs (old: {
      pname = "llama-cpp-ling";
      patches = (old.patches or [ ]) ++ [
        ./patches/llama-cpp-pr28682-ling-parser.patch
        ./patches/llama-cpp-pr28724-utf8-token-boundary.patch
      ];
    });
in
{
  services.llama-swap.settings.models = {
    "ling3.0:tiny-ud-q4_k_xl".cmd = lib.concatStringsSep " " [
      (lib.getExe' llama-cpp-ling "llama-server")
      "-m ${udq4kxl}"
      "--port \${PORT}"
      "--jinja"
      "--reasoning-format deepseek"
      "-c 131072"
      "-fa on"
      "-ngl 99"
      "--temp 1.0"
      "--top-p 0.95"
      "--top-k 20"
      "--min-p 0.0"
    ];
  };
}
