# Enable pi-chat's OpenRouter provider.
#
# The API key is stored as a clan var (`openrouter/apikey`), prompted on
# `clan vars generate` and persisted in the clan secret store. The host
# file is loaded into pi as the `openrouter-api-key` systemd credential
# so it never lands in the nix store.
{ config, ... }:
{
  clan.core.vars.generators.openrouter = {
    share = true;
    prompts.apikey.type = "hidden";
    prompts.apikey.persist = true;
  };

  services.pi-chat.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };
}
