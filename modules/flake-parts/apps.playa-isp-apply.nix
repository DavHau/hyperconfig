# `nix run .#playa-isp-apply -- [--dry-run] [--allow-pool-change]`:
# converges the DHCP pool and reservations of playa's ISP router (the LAN's
# gateway, 192.168.10.1) to `sites.playa.ispRouter` in
# ../../home-networks/sites.nix (../../tools/router-playa-isp). Run from the
# repo root: the admin password comes from `clan vars get amy
# router-playa-isp/password` (../nixos/router-playa-isp.nix).
{ lib, ... }:
let
  ispRouter = (import ../../home-networks/sites.nix).sites.playa.ispRouter;
in
{
  perSystem = { pkgs, inputs', ... }:
    let
      tool = pkgs.callPackage ../../tools/router-playa-isp { };
      program = pkgs.writeShellApplication {
        name = "playa-isp-apply";
        runtimeInputs = [ inputs'.clan-core.packages.clan-cli ];
        text = ''
          exec ${lib.getExe tool} \
            --state ${pkgs.writeText "playa-isp.json" (builtins.toJSON ispRouter)} "$@"
        '';
      };
    in
    {
      apps.playa-isp-apply = {
        type = "app";
        program = lib.getExe program;
      };
    };
}
