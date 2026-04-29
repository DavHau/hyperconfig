{lib, config, pkgs, ...}:

let
  isVM = config.services.qemuGuest.enable;
in
{
  # Override desktop.nix's modesetting-only default; NVIDIA prime offload
  # needs the nvidia driver registered.
  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];

  # Use CUDA-accelerated llama-server with native CPU optimizations.
  services.llama-swap.llama-server-package = lib.mkIf (!isVM) ((pkgs.llama-cpp.override {
    cudaSupport = true;
    rocmSupport = false;
    metalSupport = false;
    blasSupport = false;
  }).overrideAttrs (oldAttrs: {
    # cmakeFlags = (oldAttrs.cmakeFlags or []) ++ [
    #   "-DGGML_NATIVE=ON"
    # ];
    # preConfigure = ''
    #   export NIX_ENFORCE_NO_NATIVE=0
    #   ${oldAttrs.preConfigure or ""}
    # '';
  }));

  # Binary cache with prebuilt CUDA packages
  nix.settings.substituters = [ "https://cache.nixos-cuda.org" ];
  nix.settings.trusted-public-keys = [
    "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
  ];

  hardware.nvidia = {
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    dynamicBoost.enable = true;
  };

  environment.systemPackages = [ config.hardware.nvidia.package.bin ];

  services.ollama.package = lib.mkIf (!isVM) (lib.mkForce pkgs.ollama-cuda);

  # NVIDIA driver crashes on suspend when VRAM is in use.
  # Extend distro's llama-swap-suspend to also run before nvidia-suspend.
  systemd.services.llama-swap-suspend = lib.mkIf config.services.llama-swap.enable {
    before = [ "nvidia-suspend.service" ];
  };
}
