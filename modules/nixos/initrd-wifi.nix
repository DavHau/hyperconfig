# Wifi in the initrd, so a machine without a cable can reach its Tang
# servers (./tang-client.nix). Link-local only: no DHCP, no lease left over.
#
# The adapter must come back clean in stage 2. som's attempt (git log
# 1206b35..08da425) left it captured: the initrd supplicant outlived
# switch-root (DefaultDependencies = false orders nothing against it) and,
# once stopped, still left the device in a state stage 2's supplicant could
# not drive - no wifi until the driver was reloaded by hand. So here:
#   1. the supplicant conflicts with initrd-switch-root.target and
#      shutdown.target, so systemd stops it before switching root;
#   2. stopping it unloads the driver, so stage 2 probes a fresh device;
#   3. stage 2 loads the driver explicitly (boot.kernelModules) and a watchdog
#      reloads it if the interface still is not up a while after boot.
#
# Cost: the initrd sits unencrypted in the ESP, so it carries the wifi
# password. Together with the Tang JWE next to it, someone holding the disk
# and within wifi range while a Tang server is up can unlock it - the same
# exposure a wired machine has to someone plugging into the LAN.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.initrdWifi;
  confPath = "/etc/wpa_supplicant-initrd.conf";
  modprobe = "${pkgs.kmod}/bin/modprobe";
  # -i: skip modprobe.d `remove` commands. NixOS carries Ubuntu's for
  # iwlwifi, a pipeline through /run/booted-system/sw/bin that does not exist
  # in the initrd, so plain `modprobe -r iwlwifi` fails there.
  unloadDriver = map (m: "-/bin/modprobe -r -i ${m}") cfg.unloadModules;
in
{
  options.hyper.initrdWifi = {
    enable = lib.mkEnableOption "wifi in the initrd";
    interface = lib.mkOption {
      type = lib.types.str;
      example = "wlo1";
      description = "Wireless interface name, as udev names it in both stages.";
    };
    modules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "iwlwifi" "iwlmld" ];
      description = ''
        Driver modules for the initrd. List the op-mode too: iwlwifi
        request_module()s it, and without it the initrd gets a half-bound
        device and no interface.
      '';
    };
    unloadModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "iwlmld" "iwlwifi" ];
      description = "Modules to unload before switch-root, users before what they use.";
    };
    firmware = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Firmware files (relative to lib/firmware) the driver loads.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ssid and psk are prompts; the rendered config is what the initrd gets.
    # neededFor = activation: uploaded before the switch and persistent, so
    # append-initrd-secrets finds it on a `boot`-only switch too.
    clan.core.vars.generators.initrd-wifi = {
      prompts.ssid = {
        description = "SSID the initrd joins";
        persist = true;
      };
      prompts.psk = {
        description = "WPA passphrase of that network";
        type = "hidden";
        persist = true;
      };
      files.ssid.deploy = false;
      files.psk.deploy = false;
      files."wpa_supplicant.conf".neededFor = "activation";
      script = ''
        cat "$prompts/ssid" > "$out/ssid"
        cat "$prompts/psk" > "$out/psk"
        {
          echo "ctrl_interface=/run/wpa_supplicant"
          echo "update_config=0"
          echo "network={"
          printf '\tssid="%s"\n' "$(cat "$prompts/ssid")"
          printf '\tpsk="%s"\n' "$(cat "$prompts/psk")"
          echo "}"
        } > "$out/wpa_supplicant.conf"
      '';
    };

    boot.initrd.secrets.${confPath} =
      config.clan.core.vars.generators.initrd-wifi.files."wpa_supplicant.conf".path;

    # WPA2 needs ccm(aes) for the pairwise key and cmac(aes) for management
    # frame protection. Stage 2 loads them on demand; without them in the
    # initrd the handshake ends in "key addition failed" (reported as a
    # wrong PSK). aesni_intel is the fast AES those two wrap.
    boot.initrd.availableKernelModules =
      cfg.modules
      ++ [
        "ccm"
        "cmac"
      ]
      ++ lib.optional pkgs.stdenv.hostPlatform.isx86_64 "aesni_intel";
    boot.initrd.extraFirmwarePaths = cfg.firmware;

    boot.initrd.systemd.network.enable = true;
    # DHCPv4 gives the initrd some LAN address, not necessarily stage 2's
    # (another client id, maybe another MAC); rely on the fixed link-local
    # one ../unlock-target.nix adds to this network. The interface vanishes
    # with the driver unload, so nothing outlives the initrd.
    boot.initrd.systemd.network.networks."30-initrd-wifi" = {
      matchConfig.Name = cfg.interface;
      networkConfig = {
        LinkLocalAddressing = "ipv6";
        DHCP = "ipv4";
        IPv6AcceptRA = false;
        KeepConfiguration = false;
      };
    };

    boot.initrd.systemd.storePaths = [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];
    boot.initrd.systemd.services.initrd-wpa-supplicant = {
      description = "wpa_supplicant for the initrd (ssh, Tang)";
      wantedBy = [ "initrd.target" ];
      after = [
        "initrd-nixos-copy-secrets.service"
        "sys-subsystem-net-devices-${cfg.interface}.device"
      ];
      wants = [ "sys-subsystem-net-devices-${cfg.interface}.device" ];
      before = [
        "initrd-switch-root.target"
        "shutdown.target"
      ];
      conflicts = [
        "initrd-switch-root.target"
        "shutdown.target"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "simple";
        RuntimeDirectory = "wpa_supplicant";
        ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -c ${confPath} -i ${cfg.interface}";
        # Hand stage 2 a device it probes from scratch. '-': a wedged
        # unload must never block switch-root.
        ExecStopPost = unloadDriver;
        TimeoutStopSec = 10;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # Stage 2: load the driver whether or not udev coldplug notices the
    # device again.
    boot.kernelModules = cfg.modules;

    # Last resort for a machine that is only reachable over this wifi: if the
    # interface has no carrier two minutes into the boot, reload the driver.
    systemd.services.initrd-wifi-watchdog = {
      description = "Reload the wifi driver if ${cfg.interface} never comes up";
      wantedBy = [ "multi-user.target" ];
      after = [ "NetworkManager.service" ];
      path = [ pkgs.kmod pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        carrier() { [ "$(cat /sys/class/net/${cfg.interface}/carrier 2>/dev/null)" = 1 ]; }
        for _ in $(seq 120); do carrier && exit 0; sleep 1; done
        echo "${cfg.interface} has no carrier after 120s, reloading ${lib.concatStringsSep " " cfg.unloadModules}"
        ${lib.concatMapStrings (m: "${modprobe} -r -i ${m} || true\n") cfg.unloadModules}
        ${lib.concatMapStrings (m: "${modprobe} ${m}\n") cfg.modules}
      '';
    };
  };
}
