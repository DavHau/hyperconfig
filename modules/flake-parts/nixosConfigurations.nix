{ self, lib, inputs, ... }: let
  l = lib // builtins;
  system = "x86_64-linux";
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
    directory = self;
      specialArgs = {
        inherit inputs pkgsCross self;
      };
    meta.name = "DavClan";

    # add machines to their hosts
    inventory.services.importer.base = {
      roles.default.tags = ["all"];
      roles.default.extraModules = [
        inputs.clan-core.clanModules.static-hosts
      ];
    };
    inventory.services.zerotier.zt-home = {
      roles.peer.tags = [ "all" ];
      roles.controller.machines = [ "nas" ];
      # roles.moon.machines = [ "nas" ];
    };
  };
}
