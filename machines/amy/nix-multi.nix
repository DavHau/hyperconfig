{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  nix = inputs.nix-multi.packages.x86_64-linux.nix;
  nix-multi-bin = pkgs.writeScriptBin "nix-multi" ''
    exec ${nix}/bin/nix "$@"
  '';
in {
  environment.systemPackages = [
    nix-multi-bin
  ];
}
