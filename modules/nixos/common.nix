{
  config,
  lib,
  ...
}: {
  imports = [
    ./all-hardware.nix
    ./timedated-ntp.nix
    ./fast-nix-gc.nix
    ./ghostty-terminfo.nix
    ./no-ca-derivations.nix
  ];
  users.mutableUsers = false;

  # Only decides the id for a dave that doesn't exist yet: update-users-groups.pl
  # refuses to renumber a live account. amy pins 1001 (grmpf owns 1000 there).
  users.users.dave.uid = lib.mkDefault 1000;

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
  # At most 10 builds at once on every machine: more (amy and som had 40,
  # each allowed every core) starves the machine's other work.
  nix.settings.max-jobs = lib.mkDefault 10;
  nix.settings.system-features = [
    "uid-range"
  ];
  nix.settings.auto-allocate-uids = true;
  nix.settings.experimental-features = [
    "auto-allocate-uids"
    "cgroups"
    # No ca-derivations: ./no-ca-derivations.nix keeps it off (security).
  ];
}
