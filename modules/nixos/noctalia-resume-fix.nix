{ pkgs, ... }:
# Workaround for noctalia-shell showing Wi-Fi "off" (and an inert toggle)
# after resume from suspend, even though Wi-Fi is up and connected.
#
# noctalia 4.7.x reads Wi-Fi state from quickshell's `Quickshell.Networking`
# module (noctalia-qs), whose NetworkManager backend caches NM's D-Bus
# properties (WirelessEnabled, the wifi device, ...). Across s2idle the D-Bus
# connection is frozen, so NM's PropertiesChanged signals emitted around sleep
# (Wi-Fi toggling off/on) are missed; on resume the backend's cached
# `WirelessEnabled` stays stuck at its pre-sleep value — typically "off".
# The bar then shows Wi-Fi disabled and the toggle is a no-op: it writes
# WirelessEnabled=true, but NM is already true, so no PropertiesChanged is
# emitted and the stale cache never clears.
#
# noctalia 4.7.x has explicit resume handlers for several services but none
# re-syncs the network backend, and the C++ cache cannot be refreshed from
# QML — only a process restart re-reads NM. noctalia-qs 0.0.12 is the latest
# release, so there is no fixed version to bump to.
#
# A oneshot service `wantedBy` + `after` the sleep targets restarts the
# per-user noctalia-shell unit on resume (the bar reappears in ~1-2s),
# mirroring ./bluetooth-resume-fix.nix and ./amd-pstate-resume-fix.nix.
{
  systemd.services.noctalia-resume-fix = {
    description = "Restart noctalia-shell after resume (noctalia-qs Networking backend stale-state workaround)";
    wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "noctalia-resume-fix" ''
        set -u
        # Restart the bar for every user whose graphical session runs it, so
        # its Networking backend re-reads NetworkManager once the bus thaws.
        ${pkgs.systemd}/bin/loginctl list-users --no-legend | while read -r _uid user _rest; do
          [ -n "$user" ] || continue
          ${pkgs.systemd}/bin/systemctl --user -M "$user@.host" is-active --quiet noctalia-shell.service 2>/dev/null || continue
          ${pkgs.systemd}/bin/systemctl --user -M "$user@.host" restart noctalia-shell.service || true
        done
      '';
    };
  };
}
