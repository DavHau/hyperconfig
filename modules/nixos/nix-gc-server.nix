# Store settings for small-disk servers (no local development, deployed
# from elsewhere): store optimisation plus nix's free-space triggered GC
# during builds/copies. Scheduled GC: ./fast-nix-gc.nix (via ./common.nix).
{
  nix.optimise.automatic = true;
  nix.settings = {
    min-free = 2 * 1024 * 1024 * 1024;
    max-free = 6 * 1024 * 1024 * 1024;
  };
}
