# Hermes Agent (NousResearch), one microvm per user — see
# ./default.nix and siblings for the machinery. The host keeps only the
# ssh-routed `hermes` shim, the forwarded dashboard port and the spaces
# bridge.
#
# Secrets: per-secret clan vars (shared `openrouter` apikey — same var
# pi-chat uses — plus the `telegram` generator), each riding its own
# systemd credential into the guest via secretEnv (see ./default.nix).
#
# Entry points (as grmpf): `hermes` (CLI/TUI via ssh into the VM) and
# `hermes-desktop` (Electron app on the VM's backend); GUI/TUI also ship
# .desktop entries for app launchers.
{ config, lib, pkgs, inputs, ... }:
let
  # Shadow copy of the bundled simplex platform plugin with the DM send
  # fixed: upstream addresses DMs as `@<chat_id> <text>`, which the
  # daemon parses as a display-name lookup — simplex-chat >=6.3 returns
  # contactNotFound and the fire-and-forget send swallows it. The
  # structured `/_send @<id> json [...]` form addresses by numeric id and
  # escapes newlines. User plugins override bundled ones by manifest
  # name; drop this once fixed upstream.
  simplexPlatformFixed = pkgs.runCommand "simplex-platform" { } ''
    cp -r ${inputs.hermes-agent}/plugins/platforms/simplex $out
    chmod -R u+w $out
    substituteInPlace $out/adapter.py \
      --replace-fail 'cmd_str = f"@{chat_id} {content}"' \
        'cmd_str = "/_send @" + chat_id + " json " + json.dumps([{"msgContent": {"type": "text", "text": content}}])'
  '';
in
{
  imports = [ ./default.nix ];

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

  services.hermes-microvm = {
    enable = true;
    # Default brain: qwen3.6 (unsloth UD-IQ4_XS) on vit's llama-swap,
    # reached over yggdrasil (vit.d from the clan /etc/hosts; slirp DNS
    # proxies the host resolver). "custom" = any OpenAI-compatible
    # endpoint; llama-swap runs default-allow, so no key.
    settings.model = {
      default = "qwen3.6:35b-iq4_xs";
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
      # llama-swap's /v1/models omits context_length, so hermes falls back
      # to 131,072. Pin the real window: vit's llama-server runs
      # `-c 204800` (llama-swap-qwen36.nix) — keep in sync with that flag.
      context_length = 204800;
    };
    extraPlugins = [ simplexPlatformFixed ];

    # Vulkan in the guests via QEMU Venus (shared iGPU, no passthrough).
    # Smoke test in the guest: `vulkaninfo --summary` lists venus.
    gpu.enable = true;

    # SimpleX runs inside the VM; the pairing address link shows in the
    # guest's simplex-chat journal.
    simplex.enable = true;

    users.grmpf = {
      uid = 1000;
      secretEnv = {
        OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
        TELEGRAM_BOT_TOKEN = config.clan.core.vars.generators.telegram.files.token.path;
        TELEGRAM_ALLOWED_USERS = config.clan.core.vars.generators.telegram.files.allowed_users.path;
      };
      spacesGateway.enable = true;
    };
  };
}
