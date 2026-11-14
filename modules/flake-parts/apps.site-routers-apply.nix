# `nix run .#site-routers-apply -- [--dry-run] [home|playa|casa|<router> ...]`:
# converges the site routers to their part of the zt-eu bridge
# (../../home-networks/sites.nix, ../../home-networks/apply.py). Deploy edi
# first: it authorizes the routers and pins their zt-eu IPv4. Run from the
# repo root (a router without key login reads its password via clan vars).
{ lib, ... }:
let
  homeNetworks = import ../../home-networks { inherit lib; };
  # Dave's keys, root on every clan machine (../admin-ssh-keys.nix).
  adminKeys = lib.attrValues (import ../admin-ssh-keys.nix);
  states = lib.mapAttrs (_: homeNetworks.routerState adminKeys) homeNetworks.sites;
in
{
  perSystem = { pkgs, inputs', ... }:
    let
      program = pkgs.writeShellApplication {
        name = "site-routers-apply";
        runtimeInputs = [ pkgs.python3 pkgs.openssh pkgs.sshpass inputs'.clan-core.packages.clan-cli ];
        text = ''
          exec python3 ${../../home-networks/apply.py} \
            --state ${pkgs.writeText "site-routers.json" (builtins.toJSON states)} "$@"
        '';
      };
    in
    {
      apps.site-routers-apply = {
        type = "app";
        program = lib.getExe program;
      };
      # ./apply.py's uci planning against a fixture of the home router.
      checks.site-routers-apply-tests =
        pkgs.runCommand "site-routers-apply-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            cp ${../../home-networks/apply.py} apply.py
            cp ${../../home-networks/test_apply.py} test_apply.py
            python3 -m unittest -v test_apply
            touch $out
          '';
    };
}
