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
  # nmi_watchdog: hard-lockup detector (2026-07-20 freeze mitigation below).
  boot.kernelParams = [ "pcie_aspm=off" "nmi_watchdog=1" ];

  # 2026-07-20: hard freeze with zero kernel trace (journal just stops),
  # hours after a suspend/resume cycle under llama.cpp load — classic
  # nvidia-after-resume wedge. vit serves qwen3.6 to the hermes VMs
  # (vit.d:8012), so a hang takes the agents' brain offline until someone
  # walks to the machine. Make it self-recover and self-document instead:
  # hardware watchdog reboots a wedged kernel, hung tasks escalate to a
  # panic (which the watchdog then catches).
  systemd.watchdog.runtimeTime = "30s";
  boot.kernel.sysctl = {
    "kernel.hung_task_timeout_secs" = 120;
    "kernel.hung_task_panic" = 1;
  };
  # Inference-server duty: sleeping breaks vit.d for every consumer, and
  # the resume path is the prime suspect for the freeze. This machine is a
  # laptop, but it must not sleep — lid close no longer suspends.
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

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
