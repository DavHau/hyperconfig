# Hermes Agent (NousResearch), one microvm per user — see
# hermes-microvm.nix for the machinery. The host keeps only the
# ssh-routed `hermes` shim, the forwarded dashboard port and the spaces
# bridge.
#
# API key: reuses the shared `openrouter` clan var (same one pi-chat
# uses); the hermes-env generator renders the KEY=value env file handed
# into the guest and merged into $HERMES_HOME/.env there.
#
# Entry points (as grmpf): `hermes` (CLI/TUI via ssh into the VM),
# `hermes-desktop` (Electron app on the VM's backend), `hermes-vm-info`;
# GUI/TUI also ship .desktop entries for app launchers.
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
  imports = [ ./hermes-microvm.nix ];

  # Same declaration as pi-chat-openrouter.nix; identical values merge.
  clan.core.vars.generators.openrouter = {
    share = true;
    prompts.apikey.type = "hidden";
    prompts.apikey.persist = true;
  };

  clan.core.vars.generators.hermes-env = {
    dependencies = [ "openrouter" ];
    prompts.telegram_token.type = "hidden";
    prompts.telegram_token.persist = true;
    prompts.telegram_allowed_users.type = "hidden";
    prompts.telegram_allowed_users.persist = true;
    # Restarting the VM re-runs the provisioning ExecStartPre, which
    # re-assembles the guest .env from the freshly decrypted secret.
    files.env.secret = true;
    files.env.restartUnits = [ "microvm@hermes-grmpf.service" ];
    script = ''
      {
        printf 'OPENROUTER_API_KEY=%s\n' "$(cat $in/openrouter/apikey)"
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$(cat $prompts/telegram_token)"
        printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$(cat $prompts/telegram_allowed_users)"
      } > $out/env
    '';
  };

  services.hermes-microvm = {
    enable = true;
    # Default brain: qwen3.6 uncensored (heretic) on vit's llama-swap,
    # reached over yggdrasil (vit.d from the clan /etc/hosts; slirp DNS
    # proxies the host resolver). "custom" = any OpenAI-compatible
    # endpoint; llama-swap runs default-allow, so no key.
    settings.model = {
      default = "qwen3.6:35b-heretic-iq4_xs";
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
      environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
      spacesGateway.enable = true;
    };
  };
}
