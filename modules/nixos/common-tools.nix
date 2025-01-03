{
  pkgs,
  ...
}: {
  environment.systemPackages = [
    pkgs.file
  ];
}
