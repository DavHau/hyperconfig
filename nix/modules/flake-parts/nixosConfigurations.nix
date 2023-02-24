{ self, lib, inputs, ... }: let
  system = "x86_64-linux";
  nixosSystem = inputs.nixpkgs.lib.nixosSystem;
  pkgs-unstable = import inputs.nixpkgs-unstable.legacyPackages.${system};
  specialArgs = {
    inherit pkgs-unstable;
  };
  defaultModules = [
    inputs.agenix.nixosModules.age
  ];
in {
  flake = {
    nixosConfigurations.nas = nixosSystem {
      inherit specialArgs system;
      modules = defaultModules ++ [
        (self + /nas/configuration.nix)
      ];
    };

    nixosConfigurations.manu-nas = nixosSystem {
      inherit specialArgs system;
      modules = defaultModules ++ [
        (self + /manu-nas/configuration.nix)
      ];
    };
  };
}
