{
  pkgs,
  ...
}: {
  environment.systemPackages = [
    pkgs.file
    pkgs.htop
    pkgs.git
  ];
}
