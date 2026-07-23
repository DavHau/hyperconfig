{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.asus-zephyrus-gu605cw
    ../../modules/nixos/laptop-dave.nix
    ../../modules/nixos/user-dave.nix
    ./disko.nix
    ../../modules/nixos/nvidia.nix
    ../../modules/nixos/llama-swap.nix
    ../../modules/nixos/llama-swap-qwen36.nix
    ../../modules/nixos/llama-swap-yggdrasil.nix
  ];

  # Enable all hardware support
  hardware.enableAllHardware = true;

  # Kernel >= 6.18.38 triggers a correctable-AER error storm on the RTS525A
  # card reader link (0000:2c:00.0) when ASPM L0s/L1 is active, livelocking
  # boot before the LUKS prompt. Disabling ASPM stops the errors at the
  # source (verified on 26.11 gen 78). Revisit on future kernel bumps.
  # (Alternative: disable the SD card reader in BIOS, which kills the storm
  # at the device.)
  #
  # nvme_core.default_ps_max_latency_us=0: 2026-07-21 freeze diagnosis. The
  # WD PC SN5000S (15b7:5036, DRAM-less Sandisk controller) loses completion
  # interrupts chronically — every boot logs "nvme0: I/O tag N timeout,
  # completion polled" (17x in one 35-min boot). Sibling controllers
  # SN530/SN550 (15b7:5008/5009) carry NVME_QUIRK_BROKEN_MSI /
  # NVME_QUIRK_NO_DEEPEST_PS in mainline; 5036 has no quirk as of 6.18.38.
  # The drive's APST table drops to PS3 after 100ms idle and PS4 after 2s;
  # ps_max_latency_us=0 disables APST entirely so the controller stays in
  # operational states. Costs ~2W idle; relax to 5500 (allows PS3/PS4, blocks
  # PS5) if stability holds and battery matters.
  #
  # nmi_watchdog: hard-lockup detector (2026-07-20 freeze mitigation below).
  boot.kernelParams = [
    "pcie_aspm=off"
    "nmi_watchdog=1"
    "nvme_core.default_ps_max_latency_us=0"
  ];

  # 2026-07-20/21: repeated hard freezes after 1-2h uptime, zero kernel trace
  # (journal just stops mid-stream). Root cause identified 2026-07-21: NVMe
  # controller hang, not nvidia. Evidence: chronic lost-interrupt timeouts on
  # every boot (see kernelParams above), SMART clean (no media errors), and
  # the freeze signature — journald can't flush (disk dead) while PID1 keeps
  # petting the hardware watchdog from memory, which is exactly why the 30s
  # iTCO watchdog below never rebooted the frozen machine. The NVMe sits
  # behind Intel VMD (PCI domain 10000); VMD-swallowed interrupts are a known
  # failure on 2025 Zephyrus G16 (GU605) — community-verified fix is
  # disabling "Intel VMD Controller" in BIOS (Advanced menu). No Windows on
  # this disk, so the toggle is safe; disko mounts by partlabel, unaffected
  # by the PCI-topology change. ALSO: update BIOS 310 -> 311 (fixes speaker
  # amps + Modern Standby freeze fixes reported on ROG forum).
  #
  # vit serves qwen3.6 to the hermes VMs (vit.d:8012), so a hang takes the
  # agents' brain offline until someone walks to the machine. Self-recover
  # where possible: hardware watchdog reboots a wedged kernel, hung tasks
  # (D-state > 120s, e.g. everything blocked on a dead NVMe) escalate to a
  # panic, and kernel.panic reboots 10s after any panic so hung_task_panic
  # actually cycles the box instead of sitting at a dead console.
  systemd.watchdog.runtimeTime = "30s";
  boot.kernel.sysctl = {
    "kernel.hung_task_timeout_secs" = 120;
    "kernel.hung_task_panic" = 1;
    "kernel.panic" = 10;
  };
  # Inference-server duty: sleeping breaks vit.d for every consumer, and
  # the resume path is the prime suspect for the freeze. This machine is a
  # laptop, but it must not sleep — lid close no longer suspends.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # The spaces desktop profile now defaults hermes-microvm on
  # (auto-provisioning a VM per normal user), but vit's job is SERVING the
  # model to amy's agent VMs, not running its own: RAM/VRAM are budgeted
  # for qwen3.6 (see llama-swap-qwen36.nix), and dave has no declared uid
  # (the module asserts one). Opt out; to enable later, declare
  # users.users.dave.uid = 1000 and drop this line.
  services.hermes-microvm.enable = false;

  # Belt-and-braces on top of the disabled sleep targets above: logind's
  # default HandleLidSwitch=suspend still fires a (failing) suspend attempt
  # on every lid close. Ignore the lid switch entirely — closed lid never
  # suspends or powers off, on AC, battery, or docked.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Turn off the "Slash" LED array on the back of the lid. asusd (enabled by
  # the nixos-hardware gu605cw module) owns the ledbar, but the NixOS asusd
  # module has no declarative slash.ron option, so apply it via asusctl at
  # boot. --disable kills the runtime animation; the show-on-* flags are
  # firmware-persisted and cover boot/shutdown/sleep/low-battery, where the
  # lid would otherwise still light up outside asusd's control.
  systemd.services.disable-slash-led = {
    description = "Disable the lid Slash LED array";
    wantedBy = [ "multi-user.target" ];
    wants = [ "asusd.service" ];
    after = [ "asusd.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.concatStringsSep " " [
        "${config.services.asusd.package}/bin/asusctl slash --disable"
        "--show-on-boot false"
        "--show-on-shutdown false"
        "--show-on-sleep false"
        "--show-on-battery false"
        "--show-battery-warning false"
      ];
    };
  };

  # VM settings
  virtualisation.vmVariant = {
    users.users.dave.hashedPasswordFile = lib.mkForce null;
    users.users.dave.hashedPassword = lib.mkForce "$6$4PW3Q8YUR5.aep1m$fbCWXV2Lfuo53gE0Pz7BZo7V4AgRq6O6dWZ47vnzzgZsUuh7q389xzlSW9ku0SGP2kfMQhJ3BVasp01/NplRx/";  # dave

    virtualisation.qemu.options = [
      "-device virtio-vga-gl"
      "-display gtk,gl=on"
    ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;

    # Enable SSH and forward port for debugging
    virtualisation.forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];
    services.openssh.enable = true;
    home-manager.backupFileExtension = "hm-backup";

    # VM (host captures Super) → use Alt as niri's mod-key.
    services.spaces.niri.modKey = "Alt";
  };

  system.stateVersion = "25.11";
}
