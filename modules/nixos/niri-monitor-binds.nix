{ lib, ... }:
# Laptop niri keybinds: move the focused workspace to another monitor.
#
# niri's config is owned by the spaces flake, which writes a read-only
# /etc/niri/config.kdl and points NIRI_CONFIG at it (which disables niri's
# ~/.config/niri/config.kdl user lookup). To layer host-local binds on top
# without forking that file, write a small wrapper config that `include`s the
# spaces base and then defines its own `binds {}`, and repoint NIRI_CONFIG at
# the wrapper.
#
# niri's bind decoder replaces binds whose key matches a newly-defined one and
# adds the rest (niri-config/src/lib.rs: "import preconfigured-dots.kdl, then
# override some binds"). So these supersede the upstream
# `move-column-to-monitor-*` binds, which the default config places on the same
# Mod+Shift+Ctrl+<dir> chord. To keep column-to-monitor as well, move these to a
# free chord instead of reusing that one.
#
# The base is pulled in by absolute path; niri watches included files, so a
# nixos-rebuild live-reloads the merged config without a relogin (the wrapper
# is itself an /etc symlink whose target moves on deploy, same mechanism the
# spaces module relies on).
{
  environment.etc."niri/config-laptop.kdl".text = ''
    include "/etc/niri/config.kdl"

    binds {
        Mod+Shift+Ctrl+Left  hotkey-overlay-title="Move Workspace to Monitor Left"  { move-workspace-to-monitor-left; }
        Mod+Shift+Ctrl+Right hotkey-overlay-title="Move Workspace to Monitor Right" { move-workspace-to-monitor-right; }
        Mod+Shift+Ctrl+Up    hotkey-overlay-title="Move Workspace to Monitor Up"    { move-workspace-to-monitor-up; }
        Mod+Shift+Ctrl+Down  hotkey-overlay-title="Move Workspace to Monitor Down"  { move-workspace-to-monitor-down; }
        Mod+Shift+Ctrl+H     hotkey-overlay-title="Move Workspace to Monitor Left"  { move-workspace-to-monitor-left; }
        Mod+Shift+Ctrl+J     hotkey-overlay-title="Move Workspace to Monitor Down"  { move-workspace-to-monitor-down; }
        Mod+Shift+Ctrl+K     hotkey-overlay-title="Move Workspace to Monitor Up"    { move-workspace-to-monitor-up; }
        Mod+Shift+Ctrl+L     hotkey-overlay-title="Move Workspace to Monitor Right" { move-workspace-to-monitor-right; }
    }
  '';

  # Load the wrapper (which includes the spaces base) instead of the base
  # directly. mkForce overrides the NIRI_CONFIG the spaces niri module sets.
  systemd.user.services.niri.environment.NIRI_CONFIG = lib.mkForce "/etc/niri/config-laptop.kdl";
}
