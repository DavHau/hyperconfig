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
    # Re-stage /run/spaces-secrets/openrouter-api-key when the deployed key
    # changes. Without this a key rotation leaves the boot-time copy in
    # place and pi's openrouter provider 401s silently (incident
    # 2026-07-08: staged copy was 2 days older than the rotated var).
    # Running chat sessions still hold the old credential copy —
    # Mod+Shift+A (reload pi-chat) picks up the new one.
    files.apikey.restartUnits = [ "spaces-secrets-load.service" ];
  };

  services.pi-chat.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };
}
