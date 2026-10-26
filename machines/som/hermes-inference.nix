# What som's hermes agents (./hermes-agents.nix) think with: p0's Qwen as
# the provider every agent knows and the seed-once default brain, and, for
# an agent with `openrouter`, the shared OpenRouter key.
#
# Per agent this derives:
#   - secretEnv P0_API_KEY (always: providers.p0 below names it) from the
#     shared inference-api-key var, and OPENROUTER_API_KEY from the shared
#     openrouter var when `openrouter` is on,
#   - restartUnits on both vars, aimed at hermes-agent-<agent>,
#   - oh-my-pi on p0 through a per-user token copy
#     (../../modules/nixos/inference-api-key.nix).
#
# Seeding is safe on a host with existing agents: the seed writes only
# when config.yaml has no `model` key.
{ config, lib, ... }:
let
  agents = config.services.hyperhermes.agents;
  vars = config.clan.core.vars.generators;
  hermesAgent = name: "hermes-agent-${name}.service";
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.openrouter = lib.mkEnableOption "the shared openrouter/apikey var as the agent's OPENROUTER_API_KEY";
          config.secretEnv = {
            P0_API_KEY = vars.inference-api-key.files.token.path;
          }
          // lib.optionalAttrs config.openrouter {
            OPENROUTER_API_KEY = vars.openrouter.files.apikey.path;
          };
        }
      )
    );
  };

  config = {
    clan.core.vars.generators = {
      inference-api-key.files.token.restartUnits = map hermesAgent (lib.attrNames agents);
      openrouter.files.apikey.restartUnits = map hermesAgent (
        lib.attrNames (lib.filterAttrs (_: a: a.openrouter) agents)
      );
    };

    hyper.inferenceApiKey.users = lib.attrNames agents;

    services.hyperhermes = {
      settings.providers.p0 = {
        base_url = "https://inference.p0.contact/v1";
        # Env var NAME, never the token: resolved by the agent from the
        # credential-seeded .env (hermes_cli/runtime_provider.py).
        key_env = "P0_API_KEY";
        default_model = "qwen";
        # Qwen only reasons when the chat template is told to; hermes spelling
        # of omp's compat.thinkingFormat: qwen-chat-template (omp-common.nix).
        extra_body.chat_template_kwargs.enable_thinking = true;
      };
      # Anthropic prompt-cache tier (agent/agent_init.py reads
      # prompt_caching.cache_ttl; "5m" | "1h", clamped back to 5m per
      # destination by prompt_caching.effective_cache_ttl, so non-Anthropic
      # routes are unaffected). Sessions here pause for more than five
      # minutes between turns, which is where the 1h tier's 2x write
      # premium beats re-warming the whole context; under the Claude
      # subscription (hyperhermes' claude-auth) it is flat-rate anyway.
      settings.prompt_caching.cache_ttl = "1h";
      # hermes 0.21 defaults sessions.auto_prune on (retention_days 90): the
      # gateway deletes ended sessions at startup and daily. We keep all
      # history.
      settings.sessions.auto_prune = false;
      # Session titles come from p0's Qwen regardless of the chat model.
      # hermes 0.20.2 title_generator.py passes extra_body.response_format
      # through auxiliary_client into the native Anthropic request body,
      # which api.anthropic.com rejects (400 "response_format: Extra inputs
      # are not permitted"), so on a Claude session every turn logged a
      # failed title. Named ``providers`` entries resolve here through
      # _get_named_custom_provider (key_env -> P0_API_KEY from the .env).
      settings.auxiliary.title_generation = {
        provider = "p0";
        model = "qwen";
      };
      # `custom:p0`, not `p0`: hermes 0.21.3 resolves both to the same
      # providers.p0 entry at runtime (runtime_provider source
      # custom_provider:p0), but the boot inventory (hermes_cli/
      # free_tier_bootstrap -> auth.resolve_provider("auto") ->
      # _config_model_provider) only recognises `custom`, `custom:<name>`,
      # registry ids and loopback base_urls as "configured". With a bare
      # `p0` every dashboard TUI session parked on "Setup Required" while
      # the chat itself worked. Already-seeded states were edited in place
      # (2026-09-22); the seed only writes once.
      initialModel = {
        provider = "custom:p0";
        base_url = "https://inference.p0.contact/v1";
        default = "qwen";
      };
    };
  };
}
