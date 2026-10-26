# Secrets of core from clan vars, for a host in a clan
# (https://clan.lol). This flake does not depend on clan: the importing
# system brings clan-core's NixOS module, and without `clan.core.vars` this
# module does nothing.
#
# Per agent the per-machine generator hermes-agent-ssh-<agent>: the
# agent's own ssh key, `key` readable by the agent only, `key.pub` public
# (clanLib.getPublicValue hands it to the hosts that authorize it). Its
# path becomes agents.<agent>.sshKeyFile. Generator and file names are
# what the clan's vars store holds; renaming one orphans the stored key.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  # clan.core.vars is a submodule option; its generators live inside.
  hasClan = options ? clan.core.vars;
  generatorFor = name: "hermes-agent-ssh-${name}";
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.sshKeyFile = lib.mkIf hasClan (
            lib.mkDefault config.clan.core.vars.generators.${generatorFor name}.files.key.path
          );
        }
      )
    );
  };

  # optionalAttrs, not mkIf: without clan there is no option to define.
  config = lib.optionalAttrs hasClan {
    clan.core.vars.generators = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (generatorFor name) {
        files.key = {
          secret = true;
          owner = name;
        };
        files."key.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = ''
          ssh-keygen -q -t ed25519 -N "" -C "${name}@${config.networking.hostName}" -f "$out"/key
        '';
      }
    ) cfg.agents;
  };
}
