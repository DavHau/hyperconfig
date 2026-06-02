{
  nix.settings.trusted-substituters = [
    "https://cache.clan.lol"
    "https://cache.numtide.com"
  ];
  nix.settings.substituters = [
    "https://cache.clan.lol"
    "https://cache.numtide.com"
  ];
  nix.settings.trusted-public-keys = [
    "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
  ];
}
