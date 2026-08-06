# Maple-Preview 20B-A1B (ternary MoE) 2-bit pack for llama-swap.
#
# GGUF from stamsam/maple-preview-gguf: maple-tq2_0.gguf (~5.5 GiB),
# tiered fork-ternary tq2_0 (GGML type 35) + Q4_0 embeddings/lm_head.
# ~1B active params per token (256 experts, top-8).
#
# Fork-only runtime: the `maple` architecture and the fork's tq2_0
# layout exist ONLY in github.com/stamsam/llama.cpp (branch `prism`,
# rev 9ee03ee). Mainline llama.cpp and the distro llama-server CANNOT
# load this file, so the model gets its own pinned build below.
#
# Backend choice: tq2_0 has kernels in the CPU backend and (since rev
# 9ee03ee) CUDA only -- no Vulkan. A Vulkan build would fall back to
# CPU for every ternary matmul anyway, so this is a plain CPU build
# (no CUDA/Vulkan/ROCm), with GGML_CPU_ALL_VARIANTS runtime dispatch
# like stock pkgs.llama-cpp for proper AVX-512/Zen paths.
#
# Suggested parameters (model card): `llama-server -m maple-tq2_0.gguf
# --port 8080` -- no Maple-specific flags required.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.llama-swap;

  # See llama-swap-qwen36.nix: HF's CDN resets long-lived h2 streams on
  # slow links; http1.1 + big retry budget keeps the resumed fixed-output
  # fetch monotone to completion.
  bigFetchCurlOpts = [ "--http1.1" "--retry" "99" "--retry-delay" "2" ];

  model = pkgs.fetchurl {
    url = "https://huggingface.co/stamsam/maple-preview-gguf/resolve/main/maple-tq2_0.gguf";
    hash = "sha256-CdIZICVi29F3ItyOMnNSegIRgqt/iSwqBqrEWajzoJA=";
    curlOptsList = bigFetchCurlOpts;
  };

  # Standalone build instead of pkgs.llama-cpp.overrideAttrs: the nixpkgs
  # derivation builds the server webui via npm with an npmDepsHash pinned
  # to the mainline source; the fork's tools/ui lockfile differs. The
  # webui is dead weight behind llama-swap, so it is disabled outright
  # (LLAMA_BUILD_UI=OFF; server then embeds no assets and serves the API
  # only). LLAMA_USE_PREBUILT_UI=OFF stops cmake from downloading UI
  # assets from HF mid-build (sandbox would fail on it anyway).
  llama-cpp-maple = pkgs.stdenv.mkDerivation {
    pname = "llama-cpp-maple";
    version = "prism-9ee03ee";

    src = pkgs.fetchFromGitHub {
      owner = "stamsam";
      repo = "llama.cpp";
      rev = "9ee03eec62d088a117ab916bbe489e7a3872a21f";
      hash = "sha256-lAEagz5w1RDmQAeeRRP3tdp6D9JRUk0hhfxetc9lqIE=";
    };

    nativeBuildInputs = with pkgs; [ cmake ninja pkg-config ];
    buildInputs = [ pkgs.openssl ];

    cmakeFlags = [
      (lib.cmakeBool "GGML_NATIVE" false)
      # Runtime CPU dispatch (baseline x86-64 otherwise; ~13x slower).
      (lib.cmakeBool "GGML_CPU_ALL_VARIANTS" true)
      (lib.cmakeBool "GGML_BACKEND_DL" true)
      (lib.cmakeBool "LLAMA_BUILD_SERVER" true)
      (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
      (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
      (lib.cmakeBool "LLAMA_BUILD_UI" false)
      (lib.cmakeBool "LLAMA_USE_PREBUILT_UI" false)
      (lib.cmakeBool "LLAMA_OPENSSL" true)
      (lib.cmakeBool "BUILD_SHARED_LIBS" true)
      (lib.cmakeFeature "LLAMA_BUILD_COMMIT" "9ee03ee")
    ];

    meta.mainProgram = "llama-server";
  };
in
{
  services.llama-swap.settings.models = {
    "maple-preview:tq2_0" = {
      cmd = lib.concatStringsSep " " [
        (lib.getExe' llama-cpp-maple "llama-server")
        "-m ${model}"
        "--port \${PORT}"
      ];
    };
  };
}
