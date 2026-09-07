{ lib }:
let
  spawnDefaults = {
    "SMod+A" = {
      spawn = "spaces-hermes";
      description = "Open Hermes";
      niri = {
        title = "Open Hermes";
        order = 10;
      };
    };
    "SMod+S" = {
      spawn = "spaces-voice-record-toggle";
      description = "Voice to Text";
      niri = {
        title = "Voice to Text";
        order = 30;
      };
    };
    "SMod+Shift+N" = {
      spawn = "spaces-bar-reload";
      description = "Reload bar";
      niri = {
        title = "Reload Noctalia Bar";
        order = 40;
      };
    };
    "SMod+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
      niri = {
        title = "Lock the Screen: swaylock";
        order = 60;
      };
    };
    "Ctrl+Alt+L" = {
      spawn = "spaces-screen-lock";
      description = "Lock screen";
      niri = {
        title = "Lock the Screen: swaylock";
        order = 70;
      };
    };
    "Mod+Return" = {
      spawn = "alacritty";
      description = "Terminal";
    };
  };

  navDefaults =
    let
      vimKeys = {
        left = "H";
        down = "J";
        up = "K";
        right = "L";
      };
      arrowKeys = {
        left = "Left";
        down = "Down";
        up = "Up";
        right = "Right";
      };
      focusBinds = lib.mapAttrs' (
        dir: key:
        lib.nameValuePair "Mod+${key}" {
          action = "focus-${dir}";
          description = "Focus ${dir}";
        }
      ) arrowKeys;
      moveBinds = lib.mapAttrs' (
        dir: key:
        lib.nameValuePair "Mod+Shift+${key}" {
          action = "move-${dir}";
          description = "Move ${dir}";
        }
      ) vimKeys;
    in
    focusBinds
    // moveBinds
    // {
      "Mod+Shift+Q" = {
        action = "close-window";
        description = "Close window";
      };
      "Mod+F" = {
        action = "fullscreen";
        description = "Fullscreen";
      };
      "Mod+Shift+Space" = {
        action = "toggle-float";
        description = "Toggle floating";
      };
      "Mod+Shift+R" = {
        action = "reload-config";
        description = "Reload config";
      };
      "Mod+Shift+E" = {
        action = "quit";
        description = "Exit compositor";
      };
    };

  workspaceDefaults =
    let
      switch = map (n: {
        name = "Mod+${toString n}";
        value = {
          action = "workspace-switch-${toString n}";
          description = "Workspace ${toString n}";
        };
      }) (lib.range 1 9);
      move = map (n: {
        name = "Mod+Shift+${toString n}";
        value = {
          action = "workspace-move-${toString n}";
          description = "Move to workspace ${toString n}";
        };
      }) (lib.range 1 9);
    in
    lib.listToAttrs (switch ++ move);

  checkShape =
    chord: bind:
    if
      lib.count (x: x != null) [
        (bind.spawn or null)
        (bind.action or null)
        (bind.command or null)
      ] == 1
    then
      bind
    else
      throw "modules/keybinds.nix: bind \"${chord}\" must set exactly one of spawn/action/command";

  binds = lib.mapAttrs checkShape (spawnDefaults // navDefaults // workspaceDefaults);
in
{
  modifierDefault = "Mod4";

  inherit binds;

  defaults = lib.filterAttrs (_chord: bind: bind.sway or true) binds;

  niriSpawnBinds = lib.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (chord: bind: {
      inherit chord;
      inherit (bind) spawn;
      inherit (bind.niri) title order;
    }) (lib.filterAttrs (_chord: bind: bind ? niri) binds)
  );
}
