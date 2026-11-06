# The shared OpenRouter key (spaces.openrouter; spaces' hermes microvms
# ride it in as a systemd credential, som's native agents with
# `openrouter` as OPENROUTER_API_KEY, ../../machines/som/hermes-inference.nix).
#
# The API key is stored as a clan var (`openrouter/apikey`), prompted on
# `clan vars generate` and persisted in the clan secret store. Enter the
# bare `sk-or-…` key, nothing around it.
{ config, ... }:
{
  clan.core.vars.generators.openrouter = {
    share = true;
    prompts.apikey.type = "hidden";
    prompts.apikey.persist = true;
  };

  spaces.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };
}
