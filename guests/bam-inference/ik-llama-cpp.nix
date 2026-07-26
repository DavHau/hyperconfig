# ik_llama.cpp — ikawrakow's llama.cpp fork with faster CPU/hybrid MoE
# inference (fused MoE on by default, run-time repack, better IQ-quant
# CPU kernels). Not in nixpkgs; built from source. Call with a
# CUDA-configured nixpkgs (cudaSupport + cudaCapabilities ["12.0"]).
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  pkg-config,
  cudaPackages,
}:
cudaPackages.backendStdenv.mkDerivation rec {
  pname = "ik-llama-cpp";
  version = "unstable-2026-07-25";

  src = fetchFromGitHub {
    owner = "ikawrakow";
    repo = "ik_llama.cpp";
    rev = "de55d9e2f6c24d3f0c8a8a2a296e486b2ccf80b2";
    hash = "sha256-U6Yy72ph3xHx2lB0vtuooIDXiPpcZD8wCxx8brQfQGE=";
  };

  nativeBuildInputs = [
    cmake
    pkg-config
    cudaPackages.cuda_nvcc
  ];

  buildInputs = with cudaPackages; [
    cuda_cudart
    cuda_cccl
    libcublas
  ];

  cmakeFlags = [
    (lib.cmakeBool "GGML_CUDA" true)
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "120") # sm_120 Blackwell
    (lib.cmakeBool "GGML_CCACHE" false)
    # -march=native: impure, but this derivation is always built on the
    # machine it serves on (nixos-rebuild --build-host = the guest), and
    # the CPU-side expert kernels want every SIMD feature they can get.
    (lib.cmakeBool "GGML_NATIVE" true)
    # Static ggml/llama + no build-tree RPATH: we install straight out
    # of the build dir (no upstream install rules), and the default
    # shared build leaves RPATH entries into /build/ that fixup rejects.
    (lib.cmakeBool "BUILD_SHARED_LIBS" false)
    (lib.cmakeBool "CMAKE_SKIP_BUILD_RPATH" true)
  ];

  # The cc-wrapper strips -march=native by default (purity policy),
  # which here silently drops __AVX2__ and lands in an iqk stub path
  # that doesn't even compile. Same knob nixpkgs'
  # impureUseNativeOptimizations adapter uses. The sandbox build is
  # per-machine anyway (built on the guest it runs on).
  NIX_ENFORCE_NO_NATIVE = false;
  preferLocalBuild = true;
  allowSubstitutes = false;

  # No install() rules for the example binaries upstream.
  installPhase = ''
    runHook preInstall
    install -Dm755 bin/llama-* -t $out/bin
    runHook postInstall
  '';

  meta = {
    description = "llama.cpp fork with state-of-the-art CPU/hybrid MoE performance";
    homepage = "https://github.com/ikawrakow/ik_llama.cpp";
    license = lib.licenses.mit;
    platforms = ["x86_64-linux"];
  };
}
