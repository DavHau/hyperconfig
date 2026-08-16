{config, ...}: {
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/common-tools.nix
    ../../modules/nixos/sbox.nix
    ../../modules/nixos/nix-caches.nix
    # ../../modules/nixos/dns.nix
    ./disko-xfs.nix
    ./zfs.nix
    ./nextcloud.nix
    ./vikunja.nix
    ./inference-host.nix
    ./inference-net.nix
    ./inference-vm.nix
    ../../modules/nixos/vibepn.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  boot.binfmt.emulatedSystems = ["aarch64-linux"];

  # Must not change: the vault pool's labels carry this hostId, and a mismatch
  # makes every import need -f (see ./zfs.nix).
  networking.hostId = "b411ca35";

  nix.settings.max-jobs = 1;
  nix.settings.sandbox = "relaxed";

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOirp5rceowRPLnkCT2/vlTPgxtRWPeKdMIPnJ7ixJfi ds@nintendo-ds"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfFgVZxuSVWvuNua41SaxGQxpMb6oUuCEiIF7SZpAD1 root@nintendo-ds"
  ];
  users.users.dave.openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;

  services.jackett.enable = true;
  services.jackett.openFirewall = true;
}
