# Noctalia bar icon muting/unmuting herdr's agent-state sounds.
#
# No QML: noctalia's built-in CustomButton polls `herdr-sound-toggle status`
# (JSON: icon/tooltip/iconColor) and runs `herdr-sound-toggle toggle` on
# click. herdr has no runtime mute, so the toggle flips [ui.sound] enabled
# in ~/.config/herdr/config.toml (tomlkit keeps the user's comments and
# layout) and calls `herdr server reload-config`, which applies it live.
#
# merge.sh seeds the widget into ~/.config/noctalia/settings.json as an
# extra noctalia-shell ExecStartPre (same contract as noctalia-remote-build).
{ lib, pkgs, inputs, ... }:
let
  herdr = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr;

  toggle = pkgs.writers.writePython3Bin "herdr-sound-toggle" {
    libraries = [ pkgs.python3Packages.tomlkit ];
    flakeIgnore = [ "E501" ];
  } (builtins.replaceStrings [ "@herdr@" ] [ "${herdr}/bin/herdr" ] (builtins.readFile ./toggle.py));

  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-herdr-sound-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./merge.sh;
  };
in
{
  environment.systemPackages = [ toggle ];

  systemd.user.services.noctalia-shell = {
    # After the spaces bundle's noctalia-config-merge (mkAfter), so the
    # managed settings.json is already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-herdr-sound-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
