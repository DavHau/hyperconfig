{ ... }:

{
  imports = [
    ../../modules/nixos/dyndns-porkbun.nix
  ];

  services.porkbun.ipv4Entries = [
    "bruch-bu.de/A/wg-casa"
  ];

  services.porkbun.ipv6Entries = [
    "bruch-bu.de/AAAA/wg-casa"
  ];
}
