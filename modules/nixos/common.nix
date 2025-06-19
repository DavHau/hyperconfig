{
  config,
  lib,
  ...
}: {
  imports = [
    # ./nix-caches.nix
  ];
  users.mutableUsers = false;
  users.users = {
    # root
    root = {
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf"
      ];
    };
  };

  services.openssh.enable = true;

  services.zerotierone.enable = lib.mkDefault true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce" # home
  ];

  zramSwap.enable = true;
  zramSwap.memoryPercent = 100;

  # nix features
  nix.settings.system-features = [
    "uid-range"
  ];
  nix.settings.auto-allocate-uids = true;
  nix.settings.experimental-features = [
    "auto-allocate-uids"
    "cgroups"
    "ca-derivations"
  ];
}
