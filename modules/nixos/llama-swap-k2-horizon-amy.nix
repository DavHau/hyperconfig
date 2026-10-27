# K2-Horizon-3.7B (MBZUAI IFM, 2026-09; dense decoder, 36 layers, 3.7B
# core / 5.06B stored params incl. a 250K-vocab untied embedding + head,
# 512K native ctx, Apache-2.0) + DSpark speculative decoding for
# llama-swap on amy (Framework 13, Ryzen AI 9 HX 370, Radeon 890M iGPU,
# ~90 GiB unified RAM).
#
#   - Quant: bartowski imatrix Q4_K_L (3.45 GB): Q4_K base with the
#     sensitive tensors bumped (attn_v Q8_0, attn_k Q8_0/Q6_K, half of
#     ffn_down/ffn_up and attn_output at Q6_K/Q8_0, output Q6_K) -- the
#     same idea as an unsloth UD-Q4_K_XL, which does not exist for this
#     model. No EXL3 quant of the 3.7B exists either, and exllamav3 is
#     CUDA-only (amy has no NVIDIA GPU). IFM's own eval shows plain
#     Q4_K_M is unusually lossy on this model (avg 73.2 -> 66.3; AIME
#     91.6 -> 74.1, GPQA 68.6 -> 58.5, while Q5_K_M holds 71.8), so the
#     ~6% extra bytes over Q4_K_M go to the imatrix-guided upgrades.
#   - Speculative decode: no MTP head in these weights. rasyosef's DSpark
#     draft (speculators format; 4 Qwen3-style layers, ~0.5B, block 8,
#     32K reduced draft vocab via d2t, Markov + confidence heads; reads
#     target layers 2/10/18/26/34) is converted to GGUF at build time
#     with the engine's own convert_hf_to_gguf.py (no published GGUF),
#     kept at Q8_0 like the nanbeige draft.
#     Measured on amy (2026-10-28, 3 prompts math/code/prose, ~2K
#     generated tokens at temp 1.0 / top_p 0.95, fixed seed, 2 rounds):
#     plain 9.3-10.1 t/s; n-max 2/3/4/6/8 = 15.2/16.5/15.2/16.1/14.9
#     t/s (draft acceptance 65/54/42/34/24%). The 890M is compute-bound
#     verifying wide blocks, so n-max 3 (~1.7x, ~2.6 tokens per target
#     step) beats the trained block size 8. --spec-draft-sampling
#     probabilistic is a no-op for DSpark in v0.7.0 (identical draft
#     counts), so drafting stays greedy.
#   - Engine: llama.cpp >= b11454 (K2 Horizon arch, tokenizer, chat
#     parser; DSpark speculators conversion with d2t is in v0.7.0 =
#     b11669). Fleet pkgs.llama-cpp is 0.6.0 (b11429) and the
#     nixpkgs-llama-cpp pin is 0.4.1, so the fleet package is bumped
#     to v0.7.0 here (same package.nix, only src/npm deps/build number
#     differ) until the fleet catches up. Vulkan build as in
#     llama-swap-qwen36-amy.nix.
#   - KV: 36 layers x 8 KV heads x 128 dim (GQA 4:1) = 144 KiB/token in
#     f16, ~77 KiB at q8_0 -> 128K ctx = 9.6 GiB (log: 9792 MiB). Kept
#     at 128K (not the native 512K = ~38 GiB) so RAM stays free for the
#     agent VMs. f16 KV measured no faster (15.4 t/s decode, slower
#     prefill), so q8_0 it is. -ub 1024/2048 prefilled slower than the
#     default 512 (~400 t/s on a 2.3K-token prompt), so left default.
#   - Sampling: model card recommends temperature 1.0, top_p 0.95 and
#     nothing else, so llama.cpp's top_k/min_p defaults are disabled.
#   - Chat template: GGUF-embedded (<|ifm|im_start|>, <ifm|think*>);
#     reasoning_effort defaults to "high" (card: always use high), per
#     request via chat_template_kwargs. llama.cpp's dedicated K2 Horizon
#     parser splits reasoning_content and xml/json tool calls.
{ lib, pkgs, ... }:
let
  # HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  q4kl = pkgs.fetchurl {
    url = "https://huggingface.co/bartowski/K2-Horizon-3.7B-GGUF/resolve/a84d99880ada6ef080159651ffb6f5aa96f3fb1a/K2-Horizon-3.7B-Q4_K_L.gguf";
    hash = "sha256-stfUc0oneCS6amC43LDMcvCBEABQeVDv6DWkJnMjrQg=";
    curlOptsList = bigFetchCurlOpts;
  };

  dsparkRepo = "https://huggingface.co/rasyosef/K2-Horizon-3.7B-DSpark/resolve/a0a02facb4e559859944dff36b8ec3e964b7fab7";
  dsparkWeights = pkgs.fetchurl {
    url = "${dsparkRepo}/model.safetensors";
    hash = "sha256-sfx6+5UtuAGhA8xsKkX66N7vK9Rna4Cqf030k/P9W5g=";
    curlOptsList = bigFetchCurlOpts;
  };
  dsparkConfig = pkgs.fetchurl {
    url = "${dsparkRepo}/config.json";
    hash = "sha256-65E7ySxLeVcxdQF5VowtlqUzEiCDLQdEV2J6JUB2u58=";
  };

  # The converter takes the draft's vocab/tokenizer from the target.
  targetRepo = "https://huggingface.co/IFM/K2-Horizon-3.7B/resolve/9d280ff742235796925c9fe3cf243dc1beea5c08";
  targetFiles = {
    "config.json" = "sha256-0I7moXmNsqBJqG3B+vXWJwD6gFrkINY2qu6FuHhoxnc=";
    "tokenizer.json" = "sha256-g412e3yZJf8lf+sg6qQpmo48w1uz2AVYnDc/UdLMPLY=";
    "tokenizer_config.json" = "sha256-rwDzRI4Oc081OOLeXQpHpMz9VxRJrJJcGUhhGQnKbUU=";
    "special_tokens_map.json" = "sha256-KOfEv1eq5DxLXlmy8Z9hKZJXXG0fYKrzRt6mTujG90U=";
  };
  targetDir = pkgs.linkFarm "k2-horizon-3.7b-tokenizer" (lib.mapAttrs
    (name: hash: pkgs.fetchurl { url = "${targetRepo}/${name}"; inherit hash; })
    targetFiles);

  convertPython = pkgs.python3.withPackages (ps: with ps; [
    numpy
    protobuf
    pyyaml
    safetensors
    sentencepiece
    torch
    transformers
  ]);

  dspark = pkgs.runCommand "K2-Horizon-3.7B-DSpark-Q8_0.gguf"
    { nativeBuildInputs = [ convertPython ]; }
    ''
      export HOME=$TMPDIR HF_HUB_OFFLINE=1
      mkdir draft
      ln -s ${dsparkConfig} draft/config.json
      ln -s ${dsparkWeights} draft/model.safetensors
      python ${llama-cpp-k2.src}/convert_hf_to_gguf.py draft \
        --target-model-dir ${targetDir} --outtype q8_0 --outfile $out
    '';

  llama-cpp-vulkan = pkgs.llama-cpp.override {
    vulkanSupport = true;
    cudaSupport = false;
    rocmSupport = false;
  };
  llama-cpp-k2 =
    if lib.versionAtLeast llama-cpp-vulkan.version "0.7.0" then
      llama-cpp-vulkan
    else
      llama-cpp-vulkan.overrideAttrs (finalAttrs: old: {
        version = "0.7.0";
        src = pkgs.fetchFromGitHub {
          owner = "ggml-org";
          repo = "llama.cpp";
          tag = "v${finalAttrs.version}";
          hash = "sha256-pEDYgI3AMTU+cekvRX7NNt5wddznydQSNuerswvEpsA=";
        };
        # 0.6.0's only patch (ggml-org/llama.cpp#30034) is in 0.7.0.
        patches = [ ];
        npmDepsHash = "sha256-hqYzdp1FwPhYkBP278fQXgY9NCKB6Q3P6Gko7BfP0m0=";
        preConfigure =
          builtins.replaceStrings [ "LLAMA_BUILD_NUMBER=11429" ] [ "LLAMA_BUILD_NUMBER=11669" ] old.preConfigure;
        cmakeFlags = map
          (builtins.replaceStrings
            [ "LLAMA_BUILD_NUMBER:STRING=11429" "LLAMA_BUILD_COMMIT:STRING=d812350" ]
            [ "LLAMA_BUILD_NUMBER:STRING=11669" "LLAMA_BUILD_COMMIT:STRING=620d222" ])
          old.cmakeFlags;
        # As nixpkgs' 0.7.0 package.
        disabledTests = old.disabledTests ++ [ "test-llama-context-model" ];
      });
in
{
  services.llama-swap.settings.models = {
    "k2-horizon:3.7b-q4_k_l".cmd = lib.concatStringsSep " " [
      (lib.getExe' llama-cpp-k2 "llama-server")
      "-m ${q4kl}"
      "--port \${PORT}"
      "--jinja"
      "-c 131072"
      "-fa on"
      "--cache-type-k q8_0"
      "--cache-type-v q8_0"
      "-ngl 99"
      # DSpark block-parallel speculative decode via the converted draft.
      "-md ${dspark}"
      "-ngld 99"
      "--spec-type draft-dspark"
      # Measured sweet spot on the 890M (see header).
      "--spec-draft-n-max 3"
      # Model card sampling (temperature/top_p only).
      "--temp 1.0"
      "--top-p 0.95"
      "--top-k 0"
      "--min-p 0.0"
    ];
  };
}
