{config, lib, inputs, modulesPath, pkgs, ...}: {
  imports = [
    (inputs.nixos-hardware + "/starfive/visionfive/v2")
    ../../modules/nixos/common.nix
    ../../modules/nixos/monitoring.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/riscv64.nix
    ./home-assistant.nix
    # ./odoo.nix
  ];

  # TODO: remove this once fixed in nixpkgs
  programs.fish.enable = lib.mkForce false;
  documentation.nixos.enable = false;

  nixpkgs.hostPlatform = "riscv64-linux";
  clan.core.networking.targetHost= "root@cm-pi.local";
  # clan.core.networking.buildHost= "root@cm-pi.local";

  system.stateVersion = "25.05";
  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;
  boot.initrd.systemd.enable = false;

  nixpkgs.pkgs = import inputs.nixpkgs-riscv {
    system = "x86_64-linux";
    crossSystem = "riscv64-linux";
    # config.contentAddressedByDefault = true;
  };

  nixpkgs.overlays = [(self: super: {
    nixos-facter = self.hello;
    # screen = self.hello;
  })];

  # clan.core.networking.targetHost= "root@[${config.clan.core.facts.services.zerotier.public.zerotier-ip.value}]";

  image.modules.starfive2 = ({config, ...}: {
    imports = [
      "${inputs.nixos-hardware}/starfive/visionfive/v2/sd-image.nix"
      # (modulesPath + "/installer/sd-card/sd-image.nix")
    ];
    disabledModules = [
      ./hardware-configuration.nix
      "${modulesPath}/profiles/base.nix"
    ];
    # sdImage.compressImage = false;
    # system.build.image = config.system.build.sdImage;
  });
}
