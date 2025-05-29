{ self, lib, inputs, ... }: let
  allSystems = [ "x86_64-linux" "aarch64-linux" ];

  pkgsCross = lib.genAttrs allSystems (
    buildSystem:
      lib.genAttrs allSystems (
        crossSystem:
          import inputs.nixpkgs {
            inherit crossSystem;
            system = buildSystem;
          }
      )
  );

in {
  flake = inputs.clan-core.lib.buildClan {
    inherit self;
      specialArgs = {
        inherit inputs pkgsCross self;
      };
    meta.name = "DavClan";

    # add machines to their hosts
    inventory = {
      machines = {
        bam.tags = [ "wifi-home"];
        installer.tags = [ "wifi-home" ];
        cm-pi.tags = [ "wifi-home" ];
      };
      services = {
        importer.base = {
          roles.default.tags = ["all"];
          roles.default.extraModules = [
            inputs.clan-core.clanModules.static-hosts
          ];
        };
        zerotier.zt-home = {
          roles.peer.tags = [ "all" ];
          roles.controller.machines = [ "nas" ];
          # roles.moon.machines = [ "nas" ];
        };
      };
      instances = {
        wifi-home = {
          module.name = "wifi";
          module.input = "clan-core";
          roles.default.settings.networks.home = {};
          roles.default.tags.wifi-home = {};
        };
      };
    };
  };
}
