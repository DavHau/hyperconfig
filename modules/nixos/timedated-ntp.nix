{
  config,
  lib,
  ...
}: {
  # systemd-timedated learns which unit implements NTP by reading
  # ntp-units.d/*.list from /etc/systemd, /run/systemd and /usr/lib/systemd.
  # Upstream ships 80-systemd-timesync.list inside the systemd package
  # ($out/lib/systemd/ntp-units.d), which is in none of those directories on
  # NixOS, so timedated finds zero NTP units and every SetNTP call fails --
  # surfacing as "Unable to change NTP settings" in the Plasma date/time KCM.
  #
  # The chrony/ntpd/ntpd-rs modules already work around this with
  # SYSTEMD_TIMEDATED_NTP_SERVICES; timesyncd has no such fixup, so do it here.
  systemd.services.systemd-timedated.environment =
    lib.mkIf config.services.timesyncd.enable
    {
      SYSTEMD_TIMEDATED_NTP_SERVICES = "systemd-timesyncd.service";
    };
}
