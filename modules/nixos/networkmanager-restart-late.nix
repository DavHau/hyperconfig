# Keep the network up through switch-to-configuration's daemon-reload.
#
# By default a changed NetworkManager is stopped before the reload and
# started after it, so the machine is offline for the whole reload. On vit
# (2026-11-07) the reload then hung in the generator sandbox setup on a dead
# sshfs mount, systemd wedged, and NetworkManager never came back: the
# machine stayed offline until a power cycle. With stopIfChanged = false it
# is restarted after the reload instead: the same restart, a 1-3 s gap, and
# a hanging reload leaves the machine reachable.
{ config, lib, ... }:
{
  config = lib.mkIf config.networking.networkmanager.enable {
    systemd.services.NetworkManager.stopIfChanged = false;
  };
}
