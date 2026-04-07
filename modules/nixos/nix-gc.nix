{ pkgs, lib, ... }:
{
  nix.settings = {
    system-features = [
      "kvm"
      "nixos-test"
      "benchmark"
      "big-parallel"
    ];
    trusted-users = [ "root" ];
    substituters = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
      # "https://cache.ngi0.nixos.org/"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      # "cache.ngi0.nixos.org-1:KqH5CBLNSyX184S9BKZJo1LxrxJ9ltnY2uAs5c/f1MA="
    ];
    sandbox = "relaxed";
    http2 = true;
    http-connections = 200;
    builders-use-substitutes = true;
    experimental-features = [ "nix-command" "flakes" "impure-derivations" "recursive-nix" ];
    log-lines = 25;
    min-free = 10 * 1000 * 1000 * 1000;
    max-free = 20 * 1000 * 1000 * 1000;
    connect-timeout = lib.mkForce 2;
  };
  nix.nrBuildUsers = 100;
  nix.optimise.dates = [ "*:30" ];
  # nix.optimise.automatic = true;
  # nix.gc.automatic = true;
  nix.gc.dates = "hourly";
  nix.gc.options = ''--delete-older-than 14d --max-freed "$((30 * 1024**3 - 1024 * $(df -P -k /nix/store | tail -n 1 | ${pkgs.gawk}/bin/awk '{ print $4 }')))"'';
  nix.distributedBuilds = true;
}
