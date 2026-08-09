# Wireless in the initrd, so the unlock also works without a cable.
#
# Cost: the initrd lives unencrypted in the ESP, and it carries the wifi PSK.
# Physical access to the disk therefore yields the wifi password (never the
# disk key — that one is only ever in flight).
{ config, lib, pkgs, ... }:
let
  wifi = config.clan.core.vars.generators."wifi.home".files;
  hostConf = "/etc/secrets/initrd/wpa_supplicant.conf";
  initrdConf = "/etc/wpa_supplicant.conf";
  # AX210 (8086:2725). The initrd already ships a 40-wlan0 network with DHCP.
  iface = "wlan0";
  renderConf = pkgs.writeShellApplication {
    name = "initrd-wpa-conf";
    text = builtins.readFile ./initrd-wpa-conf.sh;
  };
in
{
  boot.initrd.availableKernelModules = [ "iwlwifi" ];

  # The driver asks for the highest API it supports and walks down; these are
  # the newest three AX210 images plus its platform blob. If association fails,
  # the initrd's dmesg names the exact file it wanted.
  boot.initrd.extraFirmwarePaths = [
    "iwlwifi-ty-a0-gf-a0-83.ucode"
    "iwlwifi-ty-a0-gf-a0-81.ucode"
    "iwlwifi-ty-a0-gf-a0-79.ucode"
    "iwlwifi-ty-a0-gf-a0.pnvm"
  ];

  boot.initrd.secrets.${initrdConf} = hostConf;

  boot.initrd.systemd.storePaths = [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];
  boot.initrd.systemd.services.wpa_supplicant = {
    description = "wpa_supplicant (initrd, for remote unlock)";
    wantedBy = [ "initrd.target" ];
    after = [ "initrd-nixos-copy-secrets.service" ];
    # DefaultDependencies = false means systemd adds no implicit ordering against
    # shutdown.target, so switch-root would leave this supplicant running: a
    # stale process, its binary gone with the initrd, still holding wlan0 via
    # nl80211 - and NetworkManager then finds the device owned by a supplicant it
    # does not control, i.e. no wifi on the booted system. nixpkgs' own initrd
    # sshd wires these two explicitly for the same reason.
    before = [ "sshd.service" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "wpa_supplicant";
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -c ${initrdConf} -i ${iface}";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  system.activationScripts.initrdWifiConf = {
    deps = [ "setupSecrets" ];
    text = ''
      ${lib.getExe renderConf} ${wifi.network-name.path} ${wifi.password.path} ${hostConf}
    '';
  };
}
