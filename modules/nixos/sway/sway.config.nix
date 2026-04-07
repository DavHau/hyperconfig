{pkgs, ...}: ''
# set wallpaper
output * bg ${pkgs.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath} fill

# enable touchpad tab to click
input * {
    xkb_layout us
    xkb_variant altgr-intl
    xkb_options eurosign:e
}


# tab to click
input "type:touchpad" {
    dwt enabled
    dwtp enabled
    click_method clickfinger
    drag enabled
    drag_lock enabled
    natural_scroll enabled
    tap enabled
    tap_button_map lrm
}

# display scaling
Output 'BOE NE135A1M-NY1 Unknown' scale 1.5

# nerd font
font "FiraCode Nerd Font" Medium 11

bindsym Control+Mod1+l exec swaylock
set $term alacritty

exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=sway
exec ${pkgs.waybar}/bin/waybar --config ${import ./waybar.jsonc.nix {inherit pkgs;}} 2>&1 >/home/grmpf/sway.log &
exec ${pkgs.flameshot}/bin/flameshot &
exec ${pkgs.blueberry}/bin/blueberry-tray &

''
