{ config, pkgs, lib, inputs, self, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
    # Mainline drives the Framework EC since 6.14; the out-of-tree kmod also
    # breaks aggregateModules (no .ko.cer, nixpkgs#575192).
    { hardware.framework.enableKmod = false; }
    inputs.home-manager.nixosModules.home-manager
    # inputs.nixos-hardware.nixosModules.framework-13-7040-amd
    # inputs.nixos-hardware.nixosModules.lenovo-yoga-7-14ARH7-amdgpu
    # inputs.nixos-hardware.nixosModules.tuxedo-pulse-14-gen3
    ../../modules/nixos/dave.nix
    ../../modules/nixos/laptop.nix
    ../../modules/nixos/user-grmpf.nix
    # Live LLM ghost-text suggestions in grmpf's fish (amy's desktop account).
    ../../modules/nixos/fish-llm-suggest.nix
    { hyper.fishLlmSuggest.users = [ "grmpf" ]; }
    ../../modules/nixos/amdgpu.nix
    ../../modules/nixos/llama-swap.nix
    ../../modules/nixos/llama-swap-maple.nix
    ../../modules/nixos/llama-swap-qwen36-amy.nix
    ../../modules/nixos/llama-swap-nanbeige42-amy.nix
    ../../modules/nixos/llama-swap-ling30-tiny-amy.nix
    ../../modules/nixos/llama-swap-k2-horizon-amy.nix
    ../../modules/nixos/bluetooth-resume-fix.nix
    ../../modules/nixos/noctalia-anthropic-usage
    ../../modules/nixos/fw-fanctrl.nix
    ../../modules/nixos/amd-powersave-limits.nix
    ../../modules/nixos/powersave-panel-refresh.nix
    ../../modules/nixos/chores-on-ac.nix
    ../../modules/nixos/vibepn.nix
    ../../modules/nixos/storagebox.nix
    ../../modules/nixos/vault-nfs-client.nix
    ../../modules/nixos/router-ais.nix
    ../../modules/nixos/router-cm-beryl.nix
    ../../modules/nixos/disk-hygiene
    ../../modules/nixos/rust-build-cache.nix
    ../../modules/nixos/cloudflare-warp
    ../../modules/nixos/houses-grmpf.nix
    # nix-housing needs Landlock ABI 9 (Linux >= 7.1); 6.18 LTS only has ABI 7.
    ../../modules/nixos/kernel-latest-zfs.nix
    ./disko.nix
  ];

  # 32" 4K desk monitor: open new niri columns at a third of the screen
  # (laptop panel keeps the global 1/2 default). Merged into the
  # displays.kdl snapshot by save-niri-displays; see niri-output-extras.nix.
  niri.outputExtras."Samsung Electric Company LS32D80xU HNBY600016" = ''
    layout {
        default-column-width { proportion 0.33333; }
    }
  '';

  networking.extraHosts = "10.0.0.1 127.0.0.0";

  networking.firewall.allowedTCPPorts = [ 8085 ];
  networking.firewall.allowedUDPPorts = [ 8085 ];

  virtualisation.vmVariant = {
    imports = [ ../../modules/nixos/user-dave.nix ];
    users.users.grmpf.hashedPasswordFile = lib.mkForce null;
    users.users.grmpf.hashedPassword = lib.mkForce null;
    users.users.grmpf.initialPassword = "grmpf";

    users.users.dave.hashedPasswordFile = lib.mkForce null;
    users.users.dave.hashedPassword = lib.mkForce null;
    users.users.dave.initialPassword = "dave";

    # virtualisation.qemu.options = [
    #   "-device virtio-vga-gl"
    #   "-display gtk,gl=on"
    # ];
    virtualisation.memorySize = 8192;

    # virtualisation.forwardPorts = [
    #   { from = "host"; host.port = 2222; guest.port = 22; }
    # ];
    services.openssh.enable = true;
    services.openssh.settings.PasswordAuthentication = lib.mkForce true;
    services.openssh.settings.KbdInteractiveAuthentication = lib.mkForce true;
    home-manager.backupFileExtension = "hm-backup";

    # VM (host captures Super) → use Alt as niri's mod-key.
    services.spaces.niri.modKey = "Alt";
  };

  # No hermes microVM here: grmpf's agent moved to som (hermes agent joe,
  # machines/som/hermes-agents.nix). The spaces desktop profile defaults it
  # on; its state vault under /var/lib/hermes-microvm stays on disk.
  services.hermes-microvm.enable = false;

  # dave (clan users role) has no declared uid and on-disk got 1001 (grmpf
  # took 1000 first). Pin both so any tool that rebuilds the user DB from the
  # declarative config (userborn, fresh install) can never hand dave 1000
  # and collide with grmpf's 1000, which owns grmpf's files on disk.
  # amy-specific: on other machines dave may legitimately be 1000.
  users.users.grmpf.uid = 1000;
  users.users.dave.uid = 1001;
  # Consequence for the vault NFS export (sec=sys): uid 1000 from amy is
  # `dave` on bam, so grmpf - not amy's dave - is the principal that owns
  # files on /vault. Give grmpf the `vault` read-write group (vault-nfs-client.nix only
  # adds dave); the client sends its own gid list, so membership must be
  # local.
  users.users.grmpf.extraGroups = [ "vault" ];

  # amy roams: away from home bam is unreachable, and the shared client's
  # `hard` mount (vault-nfs-client.nix) then parks every caller (df, the
  # noctalia bar) in D state for good. softerr fails calls with ETIMEDOUT
  # instead; accepted cost: a write that times out may be lost or partially
  # applied on bam. TCP backs off linearly by timeo per retry, so defaults
  # (timeo=600, retrans=2) would still block ~6 min; timeo=50, retrans=1
  # fails after 5 s + 10 s. mount-timeout caps the automount attempt itself
  # (systemd default 90 s, during which the triggering process blocks).
  # The list merges with the module's options.
  fileSystems."/vault".options = [
    "softerr"
    "timeo=50"
    "retrans=1"
    "x-systemd.mount-timeout=10s"
  ];

  # required by zfs
  networking.hostId = "5eb1bf28";

  # Disable USB autosuspend for Intel AX210 Bluetooth — prevents adapter
  # from powering down shortly after boot (firmware load race on new card).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="8087", ATTR{idProduct}=="0032", ATTR{power/autosuspend_delay_ms}="-1"
  '';

  system.stateVersion = "19.03"; # Did you read the comment?
}
