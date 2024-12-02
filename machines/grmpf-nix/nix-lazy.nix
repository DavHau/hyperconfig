{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  nixLazy = inputs.nix-lazy.packages.x86_64-linux.nix;
  nix-lazy-bin = pkgs.writeScriptBin "nix-lazy" ''
    exec ${nixLazy}/bin/nix "$@"
  '';
in {
  environment.systemPackages = [
    nix-lazy-bin
  ];
}
