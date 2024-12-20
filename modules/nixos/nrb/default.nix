{config, lib, pkgs, ...}:
let
  nrb = pkgs.writers.writePython3Bin "nrb" {} ./nrb.py;
in
{
  environment.systemPackages = [nrb];
}
