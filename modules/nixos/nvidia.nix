{lib, config, pkgs, ...}:

let
  isVM = config.services.qemuGuest.enable;
in
{
  imports = [ ./nvidia-patchelf-split.nix ];

  # Override desktop.nix's modesetting-only default; NVIDIA prime offload
  # needs the nvidia driver registered.
  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];

  hardware.nvidia = {
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    dynamicBoost.enable = true;
  };

  environment.systemPackages = [ config.hardware.nvidia.package.bin ];

  services.ollama.package = lib.mkIf (!isVM) (lib.mkForce pkgs.ollama-cuda);
}
