{clan-core, lib, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ./disko-xfs.nix
    ./buildbot
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
