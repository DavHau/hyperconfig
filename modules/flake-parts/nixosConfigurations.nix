{ self, lib, inputs, ... }: let
  l = lib // builtins;
  system = "x86_64-linux";
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
  specialArgs = {
    inherit inputs pkgs-unstable self;
  };
  defaultModules = [ ];
  # collect all nixos modules which define hosts, prefixed with `host-`.
  hostModules' =
    l.filterAttrs (name: module: l.hasPrefix "host-" name) self.modules.nixos;

  # remove the `host-` prefix for the configuration names;
  hostModules = l.flip l.mapAttrs' hostModules'
    (name: module: {name = l.removePrefix "host-" name; value = module;});

in {
  flake = inputs.clan-core.lib.buildClan {
    directory = self;
    inherit specialArgs;
    meta.name = "DavClan";
    # machines = l.flip l.mapAttrs hostModules (name: module: {
    #   nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    #   imports =
    #     defaultModules
    #     ++ [module]
    #     ++[{networking.hostName = name;}];
    # });
  };
}
