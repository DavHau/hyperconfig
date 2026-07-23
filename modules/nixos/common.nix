{
  config,
  lib,
  ...
}: {
  imports = [
    # ./nix-caches.nix
    ./all-hardware.nix
  ];
  users.mutableUsers = false;
  # spaces' base module imports nixpkgs' profiles/perlless.nix, which flips
  # services.userborn + system.etc.overlay to mkDefault true. That combo
  # rebuilds the user DB from scratch (the overlay masks the existing
  # /etc/passwd) and userborn's allocator lets a uid-less user (dave, clan
  # users role) steal a uid a later user declares statically (grmpf uid 1000)
  # -- the 2026-07-23 amy lockout. Pin both off until userborn's allocator
  # reserves static ids (https://github.com/nikstur/userborn) and the
  # etc-overlay migration is done deliberately (reboot cutover, uids pinned).
  # Plain definitions override perlless' mkDefault; no mkForce needed.
  services.userborn.enable = false;
  system.etc.overlay.enable = false;

  programs.fish.enable = true;

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
  clan.core.sops.defaultGroups = [ "admins" ];
}
