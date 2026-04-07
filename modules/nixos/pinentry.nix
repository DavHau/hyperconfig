{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.pinentry-curses
  ];
}
