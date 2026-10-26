# Route an agent's Anthropic provider through a TeamClaude gateway
# (github.com/KarpelesLab/teamclaude) instead of a Claude login of its own:
# `services.hyperhermes.agents.<name>.teamclaude.enable`, with the gateway
# at `services.hyperhermes.teamclaude.gatewayUrl`.
#
# Per agent this sets:
#   - ANTHROPIC_TOKEN, the agent's own gateway client key (keyFile), as a
#     secretEnv credential (the owner's 0600 .env, never the store). One
#     key per agent, declared to the gateway as client `<name>`, books its
#     usage under the agent's name and lets one be revoked alone. The clan
#     module mints it as the per-machine var teamclaude-hermes-<name>;
#     declaring it to the gateway is the gateway's configuration.
#   - ANTHROPIC_BASE_URL, the gateway, as a managed .env entry.
#
# Both must come from the environment: hermes seeds an `env:ANTHROPIC_TOKEN`
# credential-pool entry whose base_url is ANTHROPIC_BASE_URL
# (hermes_cli/auth.py); a base_url in config.yaml's `model` alone still sends
# the token to api.anthropic.com. env:ANTHROPIC_TOKEN ranks first among the
# seeded anthropic sources (agent/credential_pool.py, _ANTHROPIC_SOURCE_RANK),
# but a `manual:*` entry (an interactive `hermes auth` login) ranks above
# every seeded one, so an agent switched over must not keep such an entry in
# its auth.json.
#
# A gateway pooling Claude subscriptions needs the key to carry the
# `sk-ant-oat01-` prefix (the clan generator mints it so): hermes, with
# the claude-auth module, then speaks the Claude Code OAuth shape the
# gateway's subscription accounts need.
{ config, lib, ... }:
let
  cfg = config.services.hyperhermes;
  users = lib.filterAttrs (_: a: a.teamclaude.enable) cfg.agents;
in
{
  options.services.hyperhermes = {
    teamclaude.gatewayUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://teamclaude.example.org";
      description = "Base URL of the TeamClaude gateway the agents with `teamclaude.enable` use as their Anthropic endpoint.";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options.teamclaude = {
              enable = lib.mkEnableOption "the TeamClaude gateway (services.hyperhermes.teamclaude.gatewayUrl) as the agent's Anthropic endpoint and credential";
              keyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Runtime path (outside the Nix store) of the agent's gateway
                  client key. The clan module fills it from the per-machine
                  var teamclaude-hermes-<agent>.
                '';
              };
            };
            config = lib.mkIf (config.teamclaude.enable && config.teamclaude.keyFile != null) {
              environment.ANTHROPIC_BASE_URL = lib.mkIf (cfg.teamclaude.gatewayUrl != null) (
                lib.mkDefault cfg.teamclaude.gatewayUrl
              );
              secretEnv.ANTHROPIC_TOKEN = config.teamclaude.keyFile;
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (users != { }) {
    assertions = [
      {
        assertion = cfg.teamclaude.gatewayUrl != null;
        message = "services.hyperhermes.teamclaude.gatewayUrl must be set when an agent has teamclaude.enable (${lib.concatStringsSep ", " (lib.attrNames users)}).";
      }
    ]
    ++ lib.mapAttrsToList (name: a: {
      assertion = a.teamclaude.keyFile != null;
      message = "services.hyperhermes.agents.${name}.teamclaude.keyFile must be set (or import nixosModules.clan on a clan machine).";
    }) users;
  };
}
