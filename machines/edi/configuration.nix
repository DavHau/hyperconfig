{lib, inputs, ...}: {
  imports = [
    inputs.srvos.nixosModules.mixins-cloud-init
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/common.nix
    ./reverse-proxy.nix
    ./nginx-file-server.nix
  ];

  networking.useDHCP = true;
}
