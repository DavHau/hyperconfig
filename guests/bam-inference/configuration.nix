{config, ...}: {
  imports = [
    ./common.nix
    ./common-tools.nix
    ./vllm.nix
  ];

  networking.hostName = "inference";
  boot.loader.systemd-boot.enable = true;
  # false: installed from the host via nixos-install; systemd-boot's
  # fallback copy (EFI/BOOT/BOOTX64.EFI) is what OVMF boots.
  boot.loader.efi.canTouchEfiVariables = false;
  boot.kernelParams = ["console=ttyS0,115200"];
  networking.useDHCP = true;
  services.openssh.enable = true;

  # Overlay: join the clan's yggdrasil mesh by peering with bam's ygg
  # listener on the LAN (VM is bridged onto the LAN via br0).
  services.yggdrasil = {
    enable = true;
    persistentKeys = true;
    settings.Peers = [
      "tls://192.168.8.150:6446"
    ];
  };
  networking.firewall.interfaces.tun0.allowedTCPPorts = [22 30000];

  # NVIDIA: Blackwell requires the open kernel modules, >=570.
  # nvidiaPackages.latest = 610.43.03 at lock time (2026-07-25).
  services.xserver.enable = false;
  hardware.graphics.enable = true;
  hardware.nvidia = {
    open = true;
    modesetting.enable = false;
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };
  services.xserver.videoDrivers = ["nvidia"]; # loads driver; no X server runs
  nixpkgs.config.allowUnfree = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOirp5rceowRPLnkCT2/vlTPgxtRWPeKdMIPnJ7ixJfi ds@nintendo-ds"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfFgVZxuSVWvuNua41SaxGQxpMb6oUuCEiIF7SZpAD1 root@nintendo-ds"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
    "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBMAWEy2KMRae6D0kreSie2gA7s3g8x3QVNtdotxY4MDVO2dim6kc1OlGovByt06XGa/H1kMwIlc+RhfuJ/eRioGhrJ13SrDeJegC0T1iyIIZY67WMNSj5vZ0bJOmIQvm1A== grmpf@amy"
  ];
  nix.settings.experimental-features = ["nix-command" "flakes"];
  system.stateVersion = "26.11";
}
