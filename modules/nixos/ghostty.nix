# Ghostty, Dave's default terminal on his desktops (TERMINAL in
# ./desktop.nix, niri's Mod+Return / Mod+T, nautilus, the space launchers);
# ./alacritty.nix stays installed as the fallback.
#
# The config is ~/.config/ghostty/config of every home-manager user here
# (grmpf, dave), managed and forced (a hand-made file there is replaced).
# Not a wrapper passing --config-file like ./alacritty.nix: ghostty only
# takes `+show-config`, `+list-fonts` etc. as its first argument, so any
# flag in front breaks them. The look follows the alacritty setup:
# FiraCode Nerd Font 14 and alacritty's default palette. The config is
# checked with `ghostty +validate-config` at build time.
#
# Kitty graphics protocol (images in omp etc.) is built in. Its terminfo
# (TERM=xterm-ghostty) reaches the other machines via ./ghostty-terminfo.nix.
{ pkgs, ... }:
let
  settings = {
    font-family = "FiraCode Nerd Font";
    font-size = 14;

    # alacritty 0.17's built-in colors
    background = "181818";
    foreground = "d8d8d8";
    cursor-color = "d8d8d8";
    palette = [
      "0=#181818"
      "1=#ac4242"
      "2=#90a959"
      "3=#f4bf75"
      "4=#6a9fb5"
      "5=#aa759f"
      "6=#75b5aa"
      "7=#d8d8d8"
      "8=#6b6b6b"
      "9=#c55555"
      "10=#aac474"
      "11=#feca88"
      "12=#82b8c8"
      "13=#c28cb8"
      "14=#93d3c3"
      "15=#f8f8f8"
    ];

    # niri tiles and draws the focus ring; no GTK header bar.
    window-decoration = "none";
    window-padding-x = 2;
    window-padding-y = 2;

    # One process per window: --working-directory and -e are always
    # honoured (a running single instance ignores them), which the Mod+T
    # launcher, nautilus and the ssh launchers rely on.
    gtk-single-instance = false;

    # No "really close?" prompt; tmux/afk sessions survive anyway.
    confirm-close-surface = false;
    # No update nags on a nix-managed binary.
    auto-update = "off";
  };

  raw = (pkgs.formats.keyValue { listsAsDuplicateKeys = true; }).generate "ghostty-config" settings;

  config =
    pkgs.runCommand "ghostty-config"
      {
        nativeBuildInputs = [ pkgs.ghostty ];
      }
      ''
        export HOME=$TMPDIR
        ghostty +validate-config --config-file=${raw}
        cp ${raw} $out
      '';
in
{
  environment.systemPackages = [ pkgs.ghostty ];

  home-manager.sharedModules = [
    {
      xdg.configFile."ghostty/config" = {
        source = config;
        force = true;
      };
    }
  ];
}
