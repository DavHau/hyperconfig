{clan-core, lib, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/nix-caches.nix
    ../../modules/nixos/dns.nix
    ./disko-xfs.nix
    ./buildbot
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
}
