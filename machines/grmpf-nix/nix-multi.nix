{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  nixLazy = inputs.nix-multi.packages.x86_64-linux.nix;
  nix-multi-bin = pkgs.writeScriptBin "nix-multi" ''
    exec ${nixLazy}/bin/nix "$@"
  '';
in {
  environment.systemPackages = [
    nix-multi-bin
  ];
}
