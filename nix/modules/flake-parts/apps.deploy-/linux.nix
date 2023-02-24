# populates apps.{system}.deploy-... for all linux hosts
{
  self,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: let
    mkLinuxDeploy = {
      attrName,
      hostName,
    }:
      pkgs.writeScript "deploy-${hostName}" ''
        set -Eeuo pipefail
        export PATH="${lib.makeBinPath (with pkgs; [
          nix
          rsync
        ])}:$PATH"
        set -x

        rsync -r --delete ${self}/ root@${hostName}:/tmp/deploy-flake

        ssh root@${hostName} nixos-rebuild \
          -j4 \
          switch --flake /tmp/deploy-flake#'"${attrName}"'
      '';

    mkLinuxDeployApp = attrName: config:
      lib.nameValuePair "deploy-${attrName}" {
        type = "app";
        program = builtins.toString (mkLinuxDeploy {
          inherit attrName;
          hostName = config.config.deployAddress;
        });
      };
  in {
    config.apps = lib.mapAttrs' mkLinuxDeployApp self.nixosConfigurations;
  };
}
