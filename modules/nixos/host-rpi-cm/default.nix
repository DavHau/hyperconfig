{lib, config, inputs, ...}: {
  imports = [
    inputs.nixos-generators.nixosModules.all-formats
    ../common.nix
  ];
  services.home-assistant.enable = true;
  services.home-assistant.config = {
    "automation ui" = "!include automations.yaml";
  };
  systemd.tmpfiles.rules = [
    "f ${config.services.home-assistant.configDir}/automations.yaml 0755 hass hass"
  ];
  system.stateVersion = "24.11";
  nixpkgs.hostPlatform = "aarch64-linux";
}
