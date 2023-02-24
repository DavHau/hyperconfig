{
  description = "nas home server";
  inputs  = {
    agenix.url = "github:ryantm/agenix/0.13.0";
    devshell.url = "github:numtide/devshell";
    nixpkgs.url = "nixpkgs/nixos-22.11";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      agenix,
      devshell,
      nixpkgs,
      nixpkgs-unstable,
    }@inp:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgs-unstable = import nixpkgs-unstable { inherit system; };
      specialArgs = {
        inherit pkgs-unstable;
      };
      defaultModules = [
        agenix.nixosModules.age
      ];
    in
    {
      nixosConfigurations.nas = lib.nixosSystem {
        inherit specialArgs system;
        modules = defaultModules ++ [
          ./nas/configuration.nix
        ];
      };

      nixosConfigurations.manu-nas = lib.nixosSystem {
        inherit specialArgs system;
        modules = defaultModules ++ [
          ./manu-nas/configuration.nix
        ];
      };

      devShells.${system}.default = devshell.legacyPackages.${system}.mkShell {
        packages = [
          agenix.packages.${system}.agenix
        ];
        env = [
          {name="EDITOR"; value="vim";}
        ];
      };

      # apps
      defaultApp."${system}" = self.apps."${system}".nas;
      apps."${system}" = {
        nas = {
          type = "app";
          program = toString (pkgs.writeScript "deploy" ''
            host=root@rhauer.duckdns.org
            nixos-rebuild --option builders-use-substituters true --target-host $host --build-host $host --flake .#nas switch
          '');
        };
        manu-nas = {
          type = "app";
          program = toString (pkgs.writeScript "deploy" ''
            host=root@10.241.225.42
            nixos-rebuild --target-host $host --build-host $host --flake .#manu-nas switch
          '');
        };
      };
    };
}
