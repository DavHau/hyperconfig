# The canary script (./canary.py) as a command, for ./default.nix (som's
# 10-min timer) and ./candidate.nix
# (the nightly bump's sandboxed gate for a new SearXNG pin).
{ pkgs }:
pkgs.writers.writePython3Bin "searxng-canary" {
  flakeIgnore = [ "E501" ];
} (builtins.readFile ./canary.py)
