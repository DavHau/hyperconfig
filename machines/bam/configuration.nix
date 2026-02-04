{clan-core, lib, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/nix-caches.nix
    # ../../modules/nixos/dns.nix
    ./disko-xfs.nix
    ./buildbot
    ./nextcloud.nix
    ./vikunja.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  nix.settings.max-jobs = 16;
  nix.settings.sandbox = "relaxed";
  networking.firewall.interfaces.dave.allowedTCPPorts = [
    9933
    9944
    9955
    9966
  ];
  virtualisation.docker.enable = true;
  virtualisation.docker.rootless.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOirp5rceowRPLnkCT2/vlTPgxtRWPeKdMIPnJ7ixJfi ds@nintendo-ds"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfFgVZxuSVWvuNua41SaxGQxpMb6oUuCEiIF7SZpAD1 root@nintendo-ds"
  ];

  services.jackett.enable = true;
  services.jackett.openFirewall = true;
}
