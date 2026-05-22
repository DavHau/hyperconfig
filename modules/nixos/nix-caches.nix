{
  nix.settings.trusted-substituters = [
    "https://cache.clan.lol"
    "http://pradille-nix.alternativebit.fr/"
  ];
  nix.settings.substituters = [
    "http://pradille-nix.alternativebit.fr/"
    "https://cache.clan.lol"
  ];
  nix.settings.trusted-public-keys = [
    "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
  ];
}
