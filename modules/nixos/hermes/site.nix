# Hermes Agent (NousResearch), one microvm per user — the machinery now
# lives in the spaces flake (nixosModules.hermes); this file keeps only
# amy's site wiring: clan-var secrets and the vit.d model seed.
#
# Secrets: per-secret clan vars (shared `openrouter` apikey — same var
# pi-chat uses — plus the `telegram` generator), each riding its own
# systemd credential into the guest via secretEnv.
#
# Entry points (as grmpf): `hermes` (CLI/TUI via ssh into the VM) and
# `hermes-desktop` (Electron app on the VM's backend); GUI/TUI also ship
# .desktop entries for app launchers.
{ config, lib, pkgs, inputs, ... }:
{
  imports = [ inputs.spaces.nixosModules.hermes ];

  # The module derives ports/CID/MAC from the uid and asserts it matches
  # users.users.grmpf.uid — declare it (userborn allocated 1000 for the
  # first normal user).
  users.users.grmpf.uid = 1000;

  # Same declaration as pi-chat-openrouter.nix; identical values merge.
  clan.core.vars.generators.openrouter = {
    share = true;
    prompts.apikey.type = "hidden";
    prompts.apikey.persist = true;
    # Rotation: restarting the VM re-resolves LoadCredential= from the
    # freshly decrypted var.
    files.apikey.restartUnits = [ "microvm@hermes-grmpf.service" ];
  };

  # Telegram platform secrets, one file per value (persist prompts
  # auto-materialize as files.<name> — same pattern as `openrouter`,
  # cf. pi-chat-openrouter.nix).
  clan.core.vars.generators.telegram = {
    prompts.token.type = "hidden";
    prompts.token.persist = true;
    prompts.allowed_users.type = "hidden";
    prompts.allowed_users.persist = true;
    files.token.restartUnits = [ "microvm@hermes-grmpf.service" ];
    files.allowed_users.restartUnits = [ "microvm@hermes-grmpf.service" ];
  };

  # Shared key: same var pi-chat uses.
  spaces.openrouter = {
    enable = true;
    apiKeyFile = config.clan.core.vars.generators.openrouter.files.apikey.path;
  };

  services.hermes-microvm = {
    enable = true;
    # amy has a second normal user (dave, no declared uid — the clan
    # user role) that must not get a VM; keep the pre-port behavior of
    # explicitly declared users only.
    provisionNormalUsers = false;
    # Default brain: qwen3.6 on vit's llama-swap over yggdrasil. Seeded
    # ONCE into a fresh guest config; runtime /model switches persist
    # (amy's existing guest already has a model — the seed never fires).
    initialModel = {
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
      default = "qwen3.6:35b-iq4_xs";
    };
    gpu.enable = true;
    users.grmpf = {
      secretEnv = {
        # secretEnv definition replaces the openrouter default set —
        # OPENROUTER_API_KEY must be re-listed alongside telegram.
        OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
        TELEGRAM_BOT_TOKEN = config.clan.core.vars.generators.telegram.files.token.path;
        TELEGRAM_ALLOWED_USERS = config.clan.core.vars.generators.telegram.files.allowed_users.path;
      };
      # amy does not run services.spaces-integrations (the option's new
      # default source) — keep the bridge on explicitly, as before.
      spacesGateway.enable = true;
    };
  };
}
