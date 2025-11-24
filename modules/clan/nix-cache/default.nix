{ lib, ... }:
let
  inherit (lib)
    attrNames
    flip
    ;

  varsForInstance = instanceName: pkgs: {
      clan.core.vars.generators.harmonia = {
        share = true;
        files.sign-key.secret = true;
        files.sign-key.deploy = false;
        files.pub-key.secret = false;
        script = ''
          ${pkgs.nix}/bin/nix-store --generate-binary-cache-key ${instanceName}-1 \
            $out/sign-key \
            $out/pub-key
        '';
      };
    };
in
{
  _class = "clan.service";
  manifest.name = "clan-core/nix-cache";
  manifest.description = "Serve the nix store between machines in your network";
  manifest.categories = [ "Utility" ];

  roles.server = {

    interface.options = {
      priority = lib.mkOption {
        type = lib.types.int;
        description = ''
          The priority of the cache. Lower values mean higher priority.
          The default is 50, which is a lower priority than cache.nixos.org which has 30.
        '';
        default = 50;
      };
    };

    perInstance =
      { settings, instanceName, ... }:
      {
        nixosModule =
          { config, pkgs, ... }:
          {
            imports = [
              (varsForInstance instanceName pkgs)
            ];

            clan.core.vars.generators.harmonia-private = {
              dependencies = [
                "harmonia"
              ];
              files.sign-key.secret = true;
              script = ''
                cp $in/harmonia/sign-key $out/sign-key
              '';
            };

            networking.firewall.allowedTCPPorts = [ 5000 ];

            services.harmonia.enable = true;
            # $ nix-store --generate-binary-cache-key cache.yourdomain.tld-1 harmonia.secret harmonia.pub
            services.harmonia.signKeyPaths = [ config.clan.core.vars.generators.harmonia-private.files.sign-key.path ];
            services.harmonia.settings.priority = settings.priority;
          };
      };
  };

  roles.client = {

    perInstance =
      { settings, instanceName, roles,... }:
      {
        nixosModule =
          { config, pkgs, ... }:
          {
            imports = [
              (varsForInstance instanceName pkgs)
            ];

            # trust and use the cache
            nix.settings.substituters = flip map (attrNames roles.server.machines) (
              machineName: "http://${machineName}.d:5000"
            );
            nix.settings.trusted-public-keys = [
              config.clan.core.vars.generators.harmonia.files.pub-key.value
            ];
          };
      };
  };
}
