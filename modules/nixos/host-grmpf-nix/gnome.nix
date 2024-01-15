{ pkgs, lib, ... }: {
  services.tlp.enable = lib.mkForce false;
  services.xserver = {
    enable = true;
    libinput.enable = true;
    displayManager.gdm.enable = true;
    displayManager.defaultSession = "gnome";
    desktopManager.gnome.enable = true;
  };
  environment.systemPackages = [
    pkgs.gnome.gnome-tweaks
    pkgs.gnome.dconf-editor
    pkgs.gnomeExtensions.vitals
    pkgs.gnomeExtensions.forge
    pkgs.pulseaudio
    pkgs.pamixer
  ];
  hardware.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };
  security.rtkit.enable = true;
}
