{lib, config, pkgs, ...}:

let
  isVM = config.services.qemuGuest.enable;
in
{
  # Override desktop.nix's modesetting-only default; NVIDIA prime offload
  # needs the nvidia driver registered.
  services.xserver.videoDrivers = lib.mkForce [ "nvidia" ];

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
}
