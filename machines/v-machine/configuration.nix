{ inputs, lib, ... }:
{
  imports = [
    "${inputs.nixos-example}/machines/v-machine/configuration.nix"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  programs.sbox.environment = lib.mkForce {};
  programs.sbox.packages = lib.mkForce [];
}
