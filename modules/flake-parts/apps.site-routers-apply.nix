# `nix run .#site-routers-apply -- [--dry-run] [home|playa|casa|<router> ...]`:
# converges the site routers to their part of the zt-eu bridge
# (../../home-networks/sites.nix, ../../home-networks/apply.py). Deploy edi
# first: it authorizes the routers and pins their zt-eu IPv4. Run from the
# repo root (a router without key login reads its password via clan vars).
{ self, lib, ... }:
let
  homeNetworks = import ../../home-networks { inherit lib; };
  # Dave's keys as root on every clan machine: the sshd instance's
  # authorizedKeys, read through its option like ../../home-assistant/hosts.nix.
  adminKeys = lib.attrValues
    (lib.evalModules {
      modules = [
        { options.authorizedKeys = lib.mkOption { type = lib.types.attrsOf lib.types.str; }; }
        self.clan.inventory.instances.sshd.roles.server.settings
      ];
    }).config.authorizedKeys;
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
    };
}
