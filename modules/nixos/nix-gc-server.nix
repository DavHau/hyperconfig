# Automatic store GC for small-disk servers (no local development, deployed
# from elsewhere): daily GC of generations older than a week, plus nix's
# free-space triggered GC during builds/copies.
{
  nix.gc = {
    automatic = true;
    dates = "daily";
    randomizedDelaySec = "1h";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;
  nix.settings = {
    min-free = 2 * 1024 * 1024 * 1024;
    max-free = 6 * 1024 * 1024 * 1024;
  };
}
