{lib, inputs, ...}: {
  imports = [
    inputs.srvos.nixosModules.mixins-cloud-init
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/common.nix
    ./reverse-proxy.nix
  ];

  networking.useDHCP = true;
}
