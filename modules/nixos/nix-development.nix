{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.nixos-shell
  ];
}
