{
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = lib.attrValues {
    inherit (pkgs)
      bat
      file
      git
      htop
      vim
      ;
  };
}
