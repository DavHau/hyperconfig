# Hermes Agent (NousResearch), one microvm per user — the machinery now
# lives in the spaces flake (nixosModules.hermes); this file keeps only
# amy's site wiring: clan-var secrets, the vit.d model seed and the p0
# inference provider.
#
# Secrets: per-secret clan vars (shared `openrouter` apikey — same var
# pi-chat uses — plus `telegram` and the shared `inference-api-key`), each
# riding its own systemd credential into the guest via secretEnv.
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

  # Fleet inference endpoint token. The generator itself lives in
  # ../inference-api-key.nix (imported via dave.nix) and is shared with
  # the afk/omp harness — only the VM restart hook is amy's business.
  clan.core.vars.generators.inference-api-key.files.token.restartUnits = [
    "microvm@hermes-grmpf.service"
  ];

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
    # Second brain: the fleet inference endpoint (p0 — vLLM on bam behind
    # nginx, which enforces the bearer token on /v1/*). Registered as a
    # PROVIDER only, never as the active model: `settings` is deep-merged into
    # the guest config on every boot, so pinning a model here is asserted
    # against (it would clobber the runtime choice). Switch with /model in the
    # TUI once and it persists. Model ids come from the /v1/models probe
    # (discover_models defaults true), same discovery omp uses.
    settings.providers.p0 = {
      base_url = "https://inference.p0.contact/v1";
      # Env var NAME, never the token — resolved inside the guest from the
      # credential-seeded .env (secretEnv below).
      key_env = "INFERENCE_API_KEY";
      # Qwen3.6 only reasons when the chat template is told to. This is the
      # hermes spelling of the omp-side compat.thinkingFormat:
      # qwen-chat-template toggle (see ../omp-common.nix); it reaches the wire
      # as per-request extra_body.
      extra_body.chat_template_kwargs.enable_thinking = true;
    };
    # Second control channel beside telegram. The guest runs its own
    # simplex-chat daemon; the profile address lands in
    # ~/hermes/simplex-address.txt (same path on the host). Connect to it
    # from the phone and the adapter accepts the request.
    #
    # Authorization uses the upstream pairing flow, NOT an allowlist:
    # message the agent from the phone, it replies with a one-time code,
    # and `hermes pairing approve simplex <CODE>` (run via the hermes shim,
    # which lands in the guest over vsock-ssh) approves that contactId
    # durably in the vault-backed pairing store.
    #
    # No SIMPLEX_ALLOWED_USERS on purpose. A display-name entry is an
    # authorization bypass: names are attacker-chosen profile metadata, and
    # whoever claims a listed name while no live contact holds it gets full
    # control (upstream #44729/#44730, CWE-290; the pending fix #44741
    # removes name matching entirely). A contactId entry is safe but
    # transient - ids are renumbered on every re-pair. Pairing binds the
    # actual contact that received the code, so neither problem exists.
    simplex.enable = true;
    gpu.enable = true;
    users.grmpf = {
      secretEnv = {
        # secretEnv definition replaces the openrouter default set —
        # OPENROUTER_API_KEY must be re-listed alongside telegram.
        OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
        TELEGRAM_BOT_TOKEN = config.clan.core.vars.generators.telegram.files.token.path;
        TELEGRAM_ALLOWED_USERS = config.clan.core.vars.generators.telegram.files.allowed_users.path;
        # Consumed by settings.providers.p0.key_env above. Rides its own
        # systemd credential (fw_cfg) and lands in the guest's .env, which is
        # what the ssh-launched `hermes` CLI reads too.
        INFERENCE_API_KEY = config.clan.core.vars.generators.inference-api-key.files.token.path;
      };
    };
  };
}
