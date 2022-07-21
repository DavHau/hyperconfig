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
          host=root@rhauer.duckdns.org
          nixos-rebuild --target-host $host --build-host $host --flake .#nas switch
        '';
      };
    };
}
