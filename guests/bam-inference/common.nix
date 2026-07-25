# Copied from hyperconfig modules/nixos/common.nix for the standalone guest
# flake (a flake cannot import files outside its root). Two adaptations:
# - clan.core.sops.defaultGroups dropped: no clan-core in this flake.
# - users.mutableUsers = false dropped: the VM's root console password was
#   set imperatively; freezing the user DB would silently remove it.
{
  config,
  lib,
  ...
}: {
  hardware.enableAllHardware = lib.mkDefault true;
  boot.initrd.availableKernelModules = ["vmd"];

  # perlless-profile guard from upstream common.nix (see hyperconfig for
  # the amy-lockout story); harmless to pin off here too.
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
}
