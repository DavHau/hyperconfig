{clan-core, lib, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/nix-caches.nix
    ../../modules/nixos/easytier.nix
    ./disko-xfs.nix
    ./buildbot
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  boot.binfmt.emulatedSystems = ["aarch64-linux"];
}
