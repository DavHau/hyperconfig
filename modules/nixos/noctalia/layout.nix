# The bar layout and theme, ported from the v4 settings.json on amy
# (spaces' managed center section + the user's left/right choices).
# Other modules append to `bar.default.end` at default priority; mkBefore /
# mkAfter keep the base widgets first and the control center last.
{ config, lib, ... }:
let
  cmds = config.services.spaces.commands;
in
{
  services.noctalia = {
    plugins.voice-indicator = ./plugins/voice-indicator;
    plugins.status-button = ./plugins/status-button;

    settings = {
      # Config is declarative; the first-run wizard would only offer to
      # override it (and seed noctalia's bundled wallpaper).
      shell.setup_wizard_enabled = false;
      # v4 had no wallpapers (its directory never existed); niri's own
      # background stays visible.
      wallpaper.enabled = false;
      # swaylock (spaces-screen-lock) is the locker. noctalia's own
      # lock-before-suspend raced it: niri refuses a second session lock and
      # dropped noctalia's connection, which then exited cleanly (bar gone).
      lockscreen.lock_before_suspend = false;

      theme = {
        mode = "dark";
        source = "builtin";
        builtin = "Tokyo-Night";
      };

      bar.default = {
        position = "top";
        margin_ends = 0;
        background_opacity = 0.93;
        capsule = true;
        start = [
          "launcher"
          "clock"
          "cpu"
          "cpu-temp"
          "ram"
          "active_window"
          "media"
        ];
        center = [
          "workspaces"
          "voice"
          "hermes"
        ];
        end = lib.mkMerge [
          (lib.mkBefore [
            "tray"
            "notifications"
            "battery"
            "volume"
            "brightness"
          ])
          (lib.mkAfter [ "control-center" ])
        ];
      };

      widget = {
        launcher.glyph = "rocket";
        clock.format = "{:%H:%M %a, %b %d}";
        cpu = {
          type = "sysmon";
          stat = "cpu_usage";
        };
        cpu-temp = {
          type = "sysmon";
          stat = "cpu_temp";
        };
        ram = {
          type = "sysmon";
          stat = "ram_pct";
        };
        workspaces.label_source = "id";
        voice.type = "hyperconfig/voice-indicator:indicator";
        hermes = {
          type = "custom_button";
          glyph = "robot";
          tooltip = "Left: ${cmds.hermes.name}\nRight: ${cmds.integrations.name}";
          actions = {
            left = "exec ${cmds.hermes.name}";
            right = "exec ${cmds.integrations.name}";
          };
        };
        battery.display_mode = "graphic";
        volume.show_label = false;
        brightness.show_label = false;
      };
    };
  };
}
