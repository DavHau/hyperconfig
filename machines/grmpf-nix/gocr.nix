{pkgs, ...}: let
  gocr = pkgs.writers.writeDashBin "gocr" ''
    ${pkgs.netpbm}/bin/pngtopnm - \
      | ${pkgs.gocr}/bin/gocr -
  '';
in {
  environment.systemPackages = [
    gocr
  ];
}
