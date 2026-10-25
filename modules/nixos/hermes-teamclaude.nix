# Route a native hermes agent's Anthropic provider through the TeamClaude
# gateway on the same host (./teamclaude-gateway) instead of a Claude login
# of its own: `hyper.hermes.users.<name>.teamclaude = true` (for
# hyper.hermesAgents entries: `hermes.teamclaude = true`).
#
# Per agent this derives:
#   - a dedicated gateway client key, the per-machine clan var
#     teamclaude-hermes-<name> (root-only), declared to the gateway as client
#     `<name>` (hyper.teamclaudeGateway.clientKeys), so its usage is booked
#     under the agent's name in `teamclaude status` and dropping the flag
#     revokes it on the next deploy without touching any other client;
#   - ANTHROPIC_TOKEN, that key, as a secretEnv credential (the owner's 0600
#     .env, never the store), and ANTHROPIC_BASE_URL, the gateway, as a
#     managed .env entry.
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
# The key carries the `sk-ant-oat01-` prefix like ./teamclaude-api-key.nix:
# hermes (with ./hermes-claude-auth.nix) then speaks the Claude Code OAuth
# shape the gateway's subscription accounts need.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  users = lib.filterAttrs (_: u: u.teamclaude) config.hyper.hermes.users;
  generatorFor = name: "teamclaude-hermes-${name}";
in
{
  options.hyper.hermes.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.teamclaude = lib.mkEnableOption "the TeamClaude gateway on this host as the agent's Anthropic endpoint and credential";
      }
    );
  };

  config = lib.mkIf (users != { }) {
    assertions = lib.mapAttrsToList (name: u: {
      assertion = u.native && config.services.teamclaude.enable or false;
      message = "hyper.hermes.users.${name}.teamclaude needs a native agent on the TeamClaude gateway host (./teamclaude-gateway).";
    }) users;

    clan.core.vars.generators = lib.mapAttrs' (
      name: _:
      lib.nameValuePair (generatorFor name) {
        runtimeInputs = [ pkgs.openssl ];
        script = ''
          printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
        '';
        # root-owned: only the agent unit's LoadCredential reads it.
        files.key.restartUnits = [ "hermes-agent-${name}.service" ];
      }
    ) users;

    hyper.teamclaudeGateway.clientKeys = lib.mapAttrs (name: _: generatorFor name) users;

    services.hermes-native.users = lib.mapAttrs (name: _: {
      environment.ANTHROPIC_BASE_URL = "https://teamclaude.davhau.com";
      secretEnv.ANTHROPIC_TOKEN = config.clan.core.vars.generators.${generatorFor name}.files.key.path;
    }) users;
  };
}
