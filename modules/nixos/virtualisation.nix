{ config, pkgs, ... }:
{
  # qemu
  boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" "riscv64-linux" ];

  virtualisation.docker.enable = true;
  virtualisation.docker.rootless.enable = true;
  virtualisation.docker.rootless.setSocketVariable = true;
  virtualisation.podman.enable = true;
  virtualisation.waydroid.enable = true;
  # virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.extraPackages = [ pkgs.zfs ];
  systemd.services.podman.serviceConfig = {
    ExecStart = [ "" "${config.virtualisation.podman.package}/bin/podman --storage-driver zfs $LOGGING system service" ];
  };

  # virtualbox
  # virtualisation.virtualbox.host.enable = true;
  # users.extraGroups.vboxusers.members = [ "grmpf" ];
  # virtualisation.virtualbox.host.enableExtensionPack = true;

  # libvirtd
  virtualisation.libvirtd.enable = true;
}
