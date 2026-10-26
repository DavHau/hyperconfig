# nixosConfigurations.example: a workstation running the local
# deployment (nixosModules.local-container) with ./hermes.nix inside.
# Only the boot loader and the root file system stand in for the
# workstation's own hardware config.
{
  boot.loader.systemd-boot.enable = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  system.stateVersion = "26.05";

  services.hyperhermes.localContainer = {
    enable = true;
    config = ./hermes.nix;
  };
}
