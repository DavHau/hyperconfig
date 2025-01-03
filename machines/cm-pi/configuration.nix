{config, lib, inputs, ...}: {
  imports = [
    (inputs.clan-core + "/clanModules/wifi/roles/default.nix")
    ../../modules/nixos/common.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/common-tools.nix
    ./home-assistant.nix
  ];

  nixpkgs.hostPlatform = "riscv64-linux";
  clan.core.networking.targetHost= "root@cm-pi.local";
  # clan.core.networking.buildHost= "root@cm-pi.local";
  clan.core.networking.buildHost= "grmpf@localhost";

  system.stateVersion = "25.05";
  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;
  boot.initrd.systemd.enable = false;

  nixpkgs.pkgs = import inputs.nixpkgs {
    system = "x86_64-linux";
    crossSystem = "riscv64-linux";
  };

  # clan.core.networking.targetHost= "root@[${config.clan.core.facts.services.zerotier.public.zerotier-ip.value}]";

  # clan.wifi.networks.cm-home.enable = true;
  clan.wifi.networks.phone.enable = true;

  image.modules.starfive2 = [({config, ...}: {
    imports = [
      "${inputs.nixos-hardware}/starfive/visionfive/v2/sd-image.nix"
    ];
    disabledModules = [
      ./hardware-configuration.nix
    ];
    # sdImage.compressImage = false;
    system.build.image = config.system.build.sdImage;
  })];
}
