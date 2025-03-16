{pkgs, ...}: {
  programs.sway.enable = true;
  programs.sway.wrapperFeatures.gtk = true;
  # programs.sway.extraOptions = [ "--config" "${./config}" ];
  programs.sway.extraConfig = ''
    # enable touchpad tab to click
    output * bg ${pkgs.nixos-artwork.wallpapers.simple-dark-gray.gnomeFilePath} fill
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

    bindsym Control+Mod1+l exec swaylock
  '';
}
