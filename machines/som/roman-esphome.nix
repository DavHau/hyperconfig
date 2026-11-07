# roman's (./hermes-agents.nix) ESPHome firmware builds for the devices
# in Roman's two homes (./roman-home-assistant.nix): `esphome` on the
# agent's PATH, the build and OTA upload on som, never on the HA Pis.
# OTA goes straight from som to the devices: roman's uid reaches playa's
# 192.168.10.0/24 and casa's 192.168.20.0/24 over the zerotier routes
# (../../home-networks).
#
# The configs are in ~/esphome/<site>/ (a git repo in the backed-up home,
# imported once from each HA's /config/esphome); each site's .esphome
# (build dirs, ~100M per device) is a symlink into ~/scratch/esphome/<site>,
# and the toolchains and frameworks (~1G: ESPHome's own ESP-IDF in
# ~/.cache/esphome, PlatformIO's for Arduino/ESP8266 builds at
# PLATFORMIO_CORE_DIR) go to ~/.cache (scratch,
# ../../modules/nixos/entity-storage). The skill tells the agent.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  agent = "roman";
  home = config.users.users.${agent}.home;

  # nixpkgs' esphome 2026.9.1 wrapper sets PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION
  # to the literal `'python'` (quotes included), and protobuf then refuses
  # to import, so every config with `time:` fails to compile. nixpkgs'
  # 2026.10.1 passes plain `python` (and `""`), where this map changes
  # nothing and the derivation is the unmodified one; drop it then.
  esphome = pkgs.esphome.overridePythonAttrs (old: {
    makeWrapperArgs = map (
      a:
      if a == "'python'" then
        "python"
      else if a == "''" then
        ""
      else
        a
    ) old.makeWrapperArgs;
  });

  skill = inputs.hyperhermes.lib.mkAgentSkill pkgs {
    name = "esphome";
    src = lib.fileset.toSource {
      root = ./roman-esphome-skill;
      fileset = ./roman-esphome-skill/SKILL.md;
    };
  };
in
{
  services.hyperhermes.agents.${agent} = {
    extraPackages = [ esphome ];
    skillDirs = [ "${skill}/share/skills" ];
    # PlatformIO's default is ~/.platformio, in the backed-up home.
    environment.PLATFORMIO_CORE_DIR = "${home}/.cache/platformio";
  };
}
