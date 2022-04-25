{
  description = "nas home server";
  inputs  = {
    nixpkgs.url = "nixpkgs/nixos-21.11";
  };

  outputs =
    {
      self,
      nixpkgs,
    }@inp:
    let
      lib = nixpkgs.lib;
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosConfigurations.nas = lib.nixosSystem {
        inherit system;
        modules = [
          ./nas/configuration.nix
        ];
      };

      defaultApp."${system}" = self.apps."${system}".deploy;

      apps."${system}" = {
        deploy = pkgs.writeScriptBin "deploy" ''
          nixos-rebuild --target-host root@rhauer.duckdns.org --flake .#nas switch
        '';
      };
    };
}
