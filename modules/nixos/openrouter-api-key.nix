# The shared OpenRouter key for Dave's harnesses (afk): `openrouter-api-key`
# prints it, and the builtin `openrouter` provider in models.yml names it as
# `apiKey: "!openrouter-api-key"` (see omp-common.nix), so the key is
# resolved by running the command and never sits in a config file or the
# store. Exit 1 when the key file is unreadable. Same shape as
# ./teamclaude-api-key.nix.
#
# The var itself (`openrouter/apikey`, prompted, shared) is declared in
# ./pi-chat-openrouter.nix; this module only makes it readable for the
# desktop owner and the fleet `agent` account through the group
# `openrouter-api-key` (root, which hands it to som's hermes agents and the
# containers, reads it either way).
#
# Also imported where clan is not (the infra-space container and the named
# spaces, ./spaces/afk.nix): there `keyFile` points at a credential the host
# passes in, and the group and owner are left out.
#
# One key for all of these and for som's hermes agents (a decision, not an
# accident: spend is not attributable per context; keep a credit limit on it
# in OpenRouter). Rotate with
#
#   clan vars generate som --generator openrouter --regenerate   (prompts)
#
# then deploy som, amy and vit.
{ config, lib, pkgs, options, ... }:
let
  cfg = config.hyper.openrouterApiKey;
  owner = if config.users.users ? grmpf then "grmpf" else "dave";
in
{
  options.hyper.openrouterApiKey.keyFile = lib.mkOption {
    type = lib.types.str;
    default = config.clan.core.vars.generators.openrouter.files.apikey.path;
    defaultText = lib.literalExpression "config.clan.core.vars.generators.openrouter.files.apikey.path";
    description = "The key file `openrouter-api-key` prints.";
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [
        (pkgs.writeShellApplication {
          runtimeInputs = [ pkgs.coreutils ];
          name = "openrouter-api-key";
          text = ''
            [ -r ${cfg.keyFile} ] && exec cat ${cfg.keyFile}
            echo "openrouter-api-key: ${cfg.keyFile} is not readable for $(id -un)" >&2
            exit 1
          '';
        })
      ];
    }
    (lib.optionalAttrs (options ? clan) {
      # Every account that runs a harness reads the key through this group:
      # the desktop user and, where it exists, the fleet `agent` account
      # (./agent-user.nix), which gets afk's models.yml too.
      users.groups.openrouter-api-key.members = [ owner ] ++ lib.optional (config.users.users ? agent) "agent";

      # Owner and group must exist on every importing machine (the age
      # backend's decrypt script chowns each file under `set -e`; see
      # ./teamclaude-api-key.nix).
      clan.core.vars.generators.openrouter.files.apikey = {
        inherit owner;
        group = "openrouter-api-key";
        mode = "0440";
      };
    })
  ];
}
