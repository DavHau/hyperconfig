{lib, inputs, ...}: {
  imports = [
    inputs.srvos.nixosModules.mixins-cloud-init
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/dyndns-porkbun.nix
    ./reverse-proxy.nix
    ./nginx-file-server.nix
    ./users.nix
  ];

  networking.useDHCP = true;

  services.porkbun.ipv4Entries = [
    "bruch-bu.de/A/casa"
    "bruch-bu.de/A/playa"
  ];
  services.porkbun.ipv6Entries = [
    "bruch-bu.de/AAAA/casa"
    "bruch-bu.de/AAAA/playa"
  ];
}
