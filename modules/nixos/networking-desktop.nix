{ ... }:
{
  networking.networkmanager.enable = true;
  networking.dhcpcd.extraConfig = "nohook resolv.conf";

  # MT7922 WiFi fixes:
  # 1. Disable ACPI CLC SAR table — BIOS SAR limits cap TX power well below
  #    regulatory limits (3 dBm vs 20 dBm allowed), causing ~20% retry rates.
  # 2. Disable mt76 runtime PM — the card enters D3 sleep between bursts and
  #    wakes in a degraded state, intermittently dropping throughput to <100 Mbit/s.
  boot.extraModprobeConfig = ''
    options mt7921_common disable_clc=Y
  '';
  systemd.services.mt7922-fix-runtime-pm = {
    description = "Disable mt76 runtime PM for MT7922 WiFi";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "/bin/sh -c 'for phy in /sys/kernel/debug/ieee80211/phy*/mt76/runtime-pm; do echo 0 > \"$$phy\"; done'";
    };
  };
  # networking.networkmanager.insertNameservers = [
  #   "8.8.8.8"
  # ];

  services.tailscale.enable = true;
}
