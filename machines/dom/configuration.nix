{config, ...}: {
  imports = [
    ../../modules/nixos/common-tools.nix
    ./reverse-proxy.nix
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

  users.users.git.isNormalUser = true;
  users.users.git.openssh.authorizedKeys.keys =
    config.users.users.grmpf.openssh.authorizedKeys.keys;

  users.users.grmpf.isNormalUser = true;
  users.users.grmpf.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk dave"
  ];
}
