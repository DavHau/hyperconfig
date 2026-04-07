{ lib, ... }:
{
  services.pipewire.enable = true;
  services.pipewire.alsa.enable = true;
  services.pipewire.alsa.support32Bit = lib.mkForce false;
  services.pipewire.pulse.enable = true;
  services.pipewire.jack.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.gnome.gcr-ssh-agent.enable = false;
  services.pipewire.socketActivation = false;
  systemd.user.services.pipewire.wantedBy = [ "graphical-session.target" ];
  systemd.user.services.pipewire-pulse.wantedBy = [ "pipewire.service" ];
  # security.rtkit.enable = true;
  # services.pipewire.systemWide = true;
}
