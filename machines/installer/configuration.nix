{
  config,
  clan-core,
  inputs,
  lib,
  ...
}:
{
  imports = [
    # clan-core.clanModules.trusted-nix-caches
  ];

  networking.hostName = "nixos-installer";

  clan.core.deployment.requireExplicitUpdate = true;

  nixpkgs.pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  system.stateVersion = config.system.nixos.release;

  image.modules.kexecTarball = {config, ...}: {
    imports = [
      inputs.nixos-images.nixosModules.kexec-installer
    ];
    system.build.image = lib.mkForce config.system.build.kexecInstallerTarball;

    # needed to prevent conflict in module eval
    systemd.network.networks."99-ethernet-default-dhcp".networkConfig.MulticastDNS = true;
    systemd.network.networks."99-wireless-client-dhcp".networkConfig.MulticastDNS = true;
  };
}
