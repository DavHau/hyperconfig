# Client key for the TeamClaude pooled Claude subscription gateway
# (https://teamclaude.davhau.com, ./teamclaude-gateway on som).
#
# One static key for all of our own infrastructure: a generated shared clan
# var, which `teamclaude-api-key` prints. The anthropic provider override in
# models.yml names it as `apiKey: "!teamclaude-api-key"` (see
# omp-common.nix), so every harness resolves the key by running it and no
# wrapper has to export anything. Exit 1 when the var file is unreadable.
#
# The gateway accepts it declaratively: ./teamclaude-gateway imports this
# module and declares it as the static client key `hyperconfig`
# (hyper.teamclaudeGateway.clientKeys; usage is booked under that name in
# `teamclaude status`). Other people's keys stay runtime-minted there
# (`teamclaude-keys add <name>`). Rotate with
#
#   clan vars generate som --generator teamclaude-api-key --regenerate
#
# and deploy som plus every machine importing this module.
#
# Also imported where clan is not (the infra-space container,
# ./infra-space/afk.nix): there `keyFile` points at a credential and the
# var, its group and owner are left out.
{ config, lib, pkgs, options, ... }:
let
  cfg = config.hyper.teamclaudeApiKey;
  owner = if config.users.users ? grmpf then "grmpf" else "dave";
in
{
  options.hyper.teamclaudeApiKey.keyFile = lib.mkOption {
    type = lib.types.str;
    default = config.clan.core.vars.generators.teamclaude-api-key.files.key.path;
    defaultText = lib.literalExpression "config.clan.core.vars.generators.teamclaude-api-key.files.key.path";
    description = "The key file `teamclaude-api-key` prints.";
  };

  config = lib.mkMerge [
    {
      environment.systemPackages = [
        (pkgs.writeShellApplication {
          runtimeInputs = [ pkgs.coreutils ];
          name = "teamclaude-api-key";
          text = ''
            [ -r ${cfg.keyFile} ] && exec cat ${cfg.keyFile}
            echo "teamclaude-api-key: ${cfg.keyFile} is not readable for $(id -un)" >&2
            exit 1
          '';
        })
      ];
    }
    (lib.optionalAttrs (options ? clan) {
      # Every account that runs a harness reads the key through this group: the
      # desktop user and, where it exists, the fleet `agent` account
      # (./agent-user.nix), which gets afk's models.yml too.
      users.groups.teamclaude-api-key.members = [ owner ] ++ lib.optional (config.users.users ? agent) "agent";

      clan.core.vars.generators.teamclaude-api-key = {
        share = true;
        runtimeInputs = [ pkgs.openssl ];
        # `sk-ant-oat01-` is load-bearing, as for the gateway's operator key:
        # omp presents as Claude Code (the only shape Anthropic accepts
        # subscription OAuth in) only when its key looks like a subscription
        # token, and sends it as `Authorization: Bearer`.
        script = ''
          printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
        '';
        # Owner and group must exist on every importing machine: the age
        # backend's decrypt script (clan-core nixosModules/clanCore/vars/secret/age.nix)
        # runs under `set -e` and chowns each file, so an unknown one aborts it
        # and leaves the host's remaining secrets undecrypted.
        files.key = {
          inherit owner;
          group = "teamclaude-api-key";
          mode = "0440";
        };
      };
    })
  ];
}
