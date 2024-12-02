{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.pinentry
  ];
}
