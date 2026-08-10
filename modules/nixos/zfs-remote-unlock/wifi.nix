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
  # iwlmvm is the op-mode iwlwifi request_module()s for the AX210 -- listing
  # only iwlwifi builds an initrd where the driver binds the PCI device, then
  # fails to find its op-mode: no wlan0 in the initrd, and stage 2 inherits a
  # half-attached device that its own supplicant cannot drive. mac80211,
  # cfg80211, rfkill and the rest come along as modules.dep dependencies.
  boot.initrd.availableKernelModules = [ "iwlwifi" "iwlmvm" ];

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
      # Stopping the supplicant does not hand the adapter back. The initrd
      # supplicant configures the device through nl80211 and then vanishes
      # with the initramfs; stage 2's NetworkManager-owned supplicant finds
      # ${iface} in that leftover state and cannot drive it -- the symptom is
      # a desktop that boots with dead wifi until you kill wpa_supplicant and
      # reload the driver by hand. Do exactly that here instead: drop the
      # driver while the initrd is still up, so stage 2 probes a virgin
      # device (boot.kernelModules below reloads it deterministically rather
      # than relying on udev coldplug). /bin/modprobe is the initrd's own
      # kmod (systemd initrdBin), so this needs no extra storePaths and no
      # shell; iwlmvm is iwlwifi's op-mode module and holds a reference, so
      # it has to go first. The leading '-' ignores failures: a wedged
      # unload must never block switch-root.
      ExecStopPost = [
        "-/bin/modprobe -r iwlmvm"
        "-/bin/modprobe -r iwlwifi"
      ];
      TimeoutStopSec = 10;
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  # Counterpart to the ExecStopPost unload above: never leave the adapter
  # unbound if udev's coldplug misses the re-probe.
  boot.kernelModules = [ "iwlwifi" ];

  system.activationScripts.initrdWifiConf = {
    deps = [ "setupSecrets" ];
    text = ''
      ${lib.getExe renderConf} ${wifi.network-name.path} ${wifi.password.path} ${hostConf}
    '';
  };
}
