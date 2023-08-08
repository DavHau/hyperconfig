{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  l = lib // builtins;
  nixLazy = inputs.nix-lazy.packages.x86_64-linux.nix;
  nix-lazy-bin = pkgs.writeScriptBin "nix-lazy" ''
    ${nixLazy}/bin/nix "$@"
  '';
in {
  environment.systemPackages = [
    nix-lazy-bin
  ];
}
