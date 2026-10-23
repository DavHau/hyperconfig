# Noctalia bar icon muting/unmuting herdr's agent-state sounds.
#
# A hyperconfig/status-button widget (../noctalia/plugins) polls
# `herdr-sound-toggle status` (JSON: icon/tooltip/iconColor) and runs
# `herdr-sound-toggle toggle` on click. herdr has no runtime mute, so the
# toggle flips [ui.sound] enabled in ~/.config/herdr/config.toml (tomlkit
# keeps the user's comments and layout) and calls
# `herdr server reload-config`, which applies it live.
{ lib, pkgs, inputs, ... }:
let
  herdr = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr;

  toggle = pkgs.writers.writePython3Bin "herdr-sound-toggle" {
    libraries = [ pkgs.python3Packages.tomlkit ];
    flakeIgnore = [ "E501" ];
  } (builtins.replaceStrings [ "@herdr@" ] [ "${herdr}/bin/herdr" ] (builtins.readFile ./toggle.py));
in
{
  environment.systemPackages = [ toggle ];

  services.noctalia.settings = {
    bar.default.end = [ "herdr-sound" ];
    widget.herdr-sound = {
      type = "hyperconfig/status-button:button";
      glyph = "bell";
      status_command = "${lib.getExe toggle} status";
      toggle_command = "${lib.getExe toggle} toggle";
    };
  };
}
