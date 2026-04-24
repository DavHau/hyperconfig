{lib, config, pkgs, ...}:

let
  isVM = config.services.qemuGuest.enable;
in
{
  # Register NVIDIA as a video driver (required by nvidia-container-toolkit)
  services.xserver.videoDrivers = lib.mkIf (!isVM) [ "nvidia" ];

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

  # Expose NVIDIA GPUs to rootless Docker containers via CDI
  virtualisation.docker.rootless.daemon.settings.features.cdi = !isVM;
  hardware.nvidia-container-toolkit.enable = !isVM;

  # Avoid waking the NVIDIA GPU for compositing (use Intel/AMD iGPU only)
  environment.variables = lib.mkIf (!isVM) {
    WLR_DRM_DEVICES = "/dev/dri/card1";
    __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
    __GLX_VENDOR_LIBRARY_NAME = "mesa";
  };

  services.ollama.package = lib.mkIf (!isVM) (lib.mkForce pkgs.ollama-cuda);

  # Stop llama-swap before suspend to free GPU VRAM, restart on resume.
  # The NVIDIA driver crashes on suspend when VRAM is in use.
  # Must run before nvidia-suspend.service saves VRAM.
  systemd.services.llama-swap-suspend = lib.mkIf config.services.llama-swap.enable {
    description = "Stop llama-swap before suspend";
    before = [ "nvidia-suspend.service" "systemd-suspend.service" ];
    wantedBy = [ "suspend.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.systemd}/bin/systemctl stop llama-swap.service || true
      sleep 2
    '';
  };
  systemd.services.llama-swap-resume = lib.mkIf config.services.llama-swap.enable {
    description = "Restart llama-swap after resume";
    after = [ "systemd-suspend.service" ];
    wantedBy = [ "suspend.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.systemd}/bin/systemctl start llama-swap.service || true
    '';
  };
}
