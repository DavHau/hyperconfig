{
  imports = [
    ../../modules/nixos/common-tools.nix
  ];

   networking.firewall.allowedTCPPorts = [
    30333
  ];
  networking.firewall.interfaces.dave.allowedTCPPorts = [
    9933
    9944
  ];
  virtualisation.docker.enable = true;
  virtualisation.docker.rootless.enable = true;
  clan.core.networking.targetHost = "dom.dave";
}
