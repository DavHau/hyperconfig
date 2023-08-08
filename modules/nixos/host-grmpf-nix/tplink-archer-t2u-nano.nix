{
  pkgs,
  ...
}: {
  # for tp-link archer t2u nano
  boot.extraModulePackages = [
    pkgs.linuxPackages.rtl8821au
  ];
}
