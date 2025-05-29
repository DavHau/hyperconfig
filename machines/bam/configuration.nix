{
  imports = [
    ../../modules/nixos/common.nix
    ./disko-xfs.nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
