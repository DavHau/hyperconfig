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
# `hermes-vm-info` (dashboard URL).
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
  simplexCfg = config.services.simplex-chat-daemon;
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
    # Default brain: qwen3.6 on vit's llama-swap, reached over yggdrasil
    # (vit.d resolves via the clan /etc/hosts; the guest's slirp DNS
    # proxies the host resolver, and modules/nixos/llama-swap-yggdrasil.nix
    # opens vit's port on the ygg interface). "custom" = any
    # OpenAI-compatible endpoint; llama-swap runs default-allow, so no key.
    settings.model = {
      default = "qwen3.6:35b";
      provider = "custom";
      base_url = "http://vit.d:8012/v1";
    };
    extraPlugins = [ simplexPlatformFixed ];

    users.grmpf = {
      uid = 1000;
      environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
      spacesGateway.enable = true;
      # voice mode: virtio sound card wired to grmpf's PipeWire — only on
      # machines that run a desktop audio session (laptops), never servers.
      # SECURITY: while enabled and the VM runs, the guest holds standing
      # capture access to the session's audio (mic + monitor sources).
      audio.enable = config.services.pipewire.enable;
      # The simplex daemon listens on the host's loopback; guests reach it
      # through slirp's host alias. (Shared host service: not isolated
      # between VMs — single-user setup.)
      environment = lib.optionalAttrs simplexCfg.enable (
        {
          SIMPLEX_WS_URL = "ws://10.0.2.2:${toString simplexCfg.port}";
        }
        // lib.optionalAttrs (simplexCfg.allowedUsers != [ ]) {
          SIMPLEX_ALLOWED_USERS = lib.concatStringsSep "," simplexCfg.allowedUsers;
        }
      );
    };
  };
}
