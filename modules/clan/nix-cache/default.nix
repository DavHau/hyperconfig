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
              machineName: "http://${machineName}:5000"
            );
            nix.settings.trusted-public-keys = [
              config.clan.core.vars.generators.harmonia.files.pub-key.value
            ];
          };
      };
  };
}
