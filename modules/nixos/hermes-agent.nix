# Hermes Agent (NousResearch), one microvm per user (see
# hermes-microvm.nix for the machinery). Replaces the old docker container
# mode: the upstream NixOS module now runs natively INSIDE each guest, the
# host only keeps the ssh-routed `hermes` shim, the forwarded dashboard
# port and the spaces bridge.
#
# API key: reuses the shared `openrouter` clan var (same one pi-chat uses).
# The hermes-env generator renders it into the KEY=value env file that is
# handed into grmpf's guest and merged into $HERMES_HOME/.env there.
#
# Interfaces (as grmpf): `hermes` (CLI/TUI via ssh into the VM),
# `hermes-desktop` (upstream Electron app on the VM's backend),
# `hermes-vm-info` (dashboard URL). Both GUI/TUI entry points also ship
# .desktop entries, so they show up in app launchers (fuzzel).
{ config, lib, pkgs, inputs, ... }:
let
  # Shadow copy of the bundled simplex platform plugin with the DM send
  # fixed. Upstream addresses DMs as `@<chat_id> <text>`, but the daemon
  # parses that as a display-name lookup — simplex-chat >=6.3 returns
  # contactNotFound and the fire-and-forget send swallows it, so pairing
  # codes and agent replies silently vanish. The structured
  # `/_send @<id> json [...]` form addresses by numeric id (same as the
  # group path) and escapes newlines correctly. User plugins override
  # bundled ones by manifest name, so this replaces the broken adapter
  # until it is fixed upstream; drop it then.
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
    # The guest reads the assembled .env at boot; restarting the VM re-runs
    # the provisioning ExecStartPre, which re-assembles it from the freshly
    # decrypted secret.
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
    # Default brain: qwen3.6 uncensored (HauhauCS Aggressive) on vit's
    # llama-swap, reached over yggdrasil (vit.d resolves via the clan
    # /etc/hosts; the guest's slirp DNS proxies the host resolver, and
    # modules/nixos/llama-swap-yggdrasil.nix opens vit's port on the ygg
    # interface). "custom" = any OpenAI-compatible endpoint; llama-swap
    # runs default-allow, so no key.
    settings.model = {
      default = "qwen3.6:35b-uncensored-iq4_xs";
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
      # llama-swap's /v1/models omits context_length, so hermes probe-downs
      # to its 131,072 fallback. Pin the real window: vit's llama-server
      # runs `-c 204800` (llama-swap-qwen36.nix; model native max 262,144).
      # Keep in sync with the -c flag there.
      context_length = 204800;
    };
    extraPlugins = [ simplexPlatformFixed ];

    # Vulkan in the guests via QEMU Venus on amy's Radeon 890M (shared
    # with the host desktop, no passthrough). Smoke test from the guest:
    # `vulkaninfo --summary` should list the venus driver.
    gpu.enable = true;

    # SimpleX runs inside the VM; pairing is unchanged (journalctl inside
    # the guest shows the simplex:/ address link).
    simplex.enable = true;

    users.grmpf = {
      uid = 1000;
      environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
      spacesGateway.enable = true;
    };
  };
}
