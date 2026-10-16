/*
  Fleet-wide store GC (imported by ./common.nix, so every machine gets it):
  daily fast-nix-gc (DavHau's fork, flake input fast-nix-gc) deleting
  profile generations older than 14 days, plus gcroots/auto entries older
  than that: nix-direnv devshells not loaded within the window and other
  auto roots (`nix build` result links, ...) registered before it. The
  active generation of every profile stays.

  Replaces nix.gc everywhere; nix's min-free/max-free (per-machine
  nix.settings) remain the build-time safety net. Laptops gate the timer
  behind ./chores-on-ac.nix.
*/
{ inputs, ... }:
{
  imports = [ inputs.fast-nix-gc.nixosModules.default ];

  services.fast-nix-gc = {
    enable = true;
    automatic = true;
    dates = "daily";
    randomizedDelaySec = "1h";
    deleteOlderThan = "14d";
    # Keep paths fetched for builds of the last day.
    keepRecent = "1d";
  };

  # One collector: nix-collect-garbage would race fast-nix-gc on the same
  # store.
  nix.gc.automatic = false;
}
