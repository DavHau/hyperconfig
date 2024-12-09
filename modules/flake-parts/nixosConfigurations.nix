{ self, lib, inputs, ... }: let
  l = lib // builtins;
  system = "x86_64-linux";
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  specialArgs = {
    inherit inputs pkgs-unstable self;
  };

in {
  flake = inputs.clan-core.lib.buildClan {
    directory = self;
    inherit specialArgs;
    # meta.name = "DavClan";
    inventory.services.zerotier.zt-home = {
      roles.peer.tags = [ "all" ];
      roles.controller.machines = [ "nas" ];
      # roles.moon.machines = [ "nas" ];
    };
  };
}
