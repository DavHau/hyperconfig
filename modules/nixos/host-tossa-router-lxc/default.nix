{config, lib, inputs, ...}: {
  imports = [
    inputs.nixos-generators.nixosModules.all-formats
  ];
  services.nginx.enable = true;
  nixpkgs.hostPlatform = "aarch64-linux";
}
