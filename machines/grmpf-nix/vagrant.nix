{pkgs, ...}: {
  virtualisation.virtualbox.host.enable = true;
  environment.systemPackages = [
    pkgs.vagrant
  ];
}
