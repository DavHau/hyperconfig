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

        POSITIONAL_ARGS=()

        while [[ $# -gt 0 ]]; do
          case $1 in
            -e|--extension)
              EXTENSION="$2"
              shift # past argument
              shift # past value
              ;;
            -s|--searchpath)
              SEARCHPATH="$2"
              shift # past argument
              shift # past value
              ;;
            --local)
              local=YES
              shift # past argument
              ;;
            -*|--*)
              echo "Unknown option $1"
              exit 1
              ;;
            *)
              POSITIONAL_ARGS+=("$1") # save positional arg
              shift # past argument
              ;;
          esac
        done

        set -- "''${POSITIONAL_ARGS[@]}" # restore positional parameters

        mode="''${POSITIONAL_ARGS[0]:-switch}"

        # if --local is passed, execute nixos-rebuild locally with --target host set to the remote host
        if [[ "''${local:-}" == "YES" ]]; then
          shift
          nixos-rebuild \
            -j4 \
            --target-host root@"${hostName}" \
            --flake ".#${attrName}" \
            ''${mode:-switch}
          exit 0
        fi

        rsync -r --delete --exclude .git \
          ${self}/ root@${hostName}:/tmp/deploy-flake

        ssh root@${hostName} nixos-rebuild \
          -j4 \
          --flake /tmp/deploy-flake#'"${attrName}"' \
          ''${mode:-switch}
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
