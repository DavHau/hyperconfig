{
  config,
  lib,
  pkgs,
  ...
}: let
  cura = pkgs.cura.override {
    plugins = [
      pkgs.curaPlugins.octoprint
    ];
  };
in {
  environment.systemPackages = [
    cura
  ];
}
