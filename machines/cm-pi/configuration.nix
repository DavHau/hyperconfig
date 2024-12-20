{config, lib, inputs, ...}: {
  imports = [
    inputs.raspberry-pi-nix.nixosModules.raspberry-pi
    inputs.raspberry-pi-nix.nixosModules.sd-image
    (inputs.clan-core + "/clanModules/wifi/roles/default.nix")
    ../../modules/nixos/common.nix
    ../../modules/nixos/monitoring.nix
    ./home-assistant.nix
  ];

  disabledModules = [
    ./hardware-configuration.nix
  ];

  raspberry-pi-nix.board = "bcm2712";
  raspberry-pi-nix.kernel-build-system = "x86_64-linux";
  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;
  raspberry-pi-nix.uboot.enable = false;
  boot.initrd.systemd.enable = false;

  # clan.core.networking.targetHost= "root@[${config.clan.core.facts.services.zerotier.public.zerotier-ip.value}]";
  clan.core.networking.targetHost= "root@cm-pi.local";
  # clan.core.networking.buildHost = "grmpf@localhost";

  nixpkgs.hostPlatform = "aarch64-linux";

  # clan.wifi.networks.cm-home.enable = true;
  clan.wifi.networks.phone.enable = true;
}
