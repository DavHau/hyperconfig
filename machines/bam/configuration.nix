{
  imports = [
    ../../modules/nixos/common.nix
    ./disk.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
