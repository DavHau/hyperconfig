{
  imports = [
    ../../modules/nixos/common-tools.nix
  ];
  networking.firewall.allowedTCPPorts = [
    30333
  ];
  virtualisation.docker.enable = true;
  virtualisation.docker.rootless.enable = true;
}
