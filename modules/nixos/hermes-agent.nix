# Hermes Agent (NousResearch) gateway, upstream NixOS module in container
# mode: persistent Ubuntu container on rootful docker with /nix/store
# bind-mounted read-only. The agent can apt/pip/npm install inside the
# container; installs persist across restarts and rebuilds (lost only when
# the container identity changes: image/volumes/options).
#
# API key: reuses the shared `openrouter` clan var (same one pi-chat uses).
# The hermes-env generator renders it into the KEY=value env file that the
# hermes module merges into $HERMES_HOME/.env at activation time.
#
# Host CLI: addToSystemPackages puts `hermes` on PATH and routes every
# invocation into the container (needs docker group membership).
{ config, lib, pkgs, inputs, ... }:
let
  # Shadow copy of the bundled simplex platform plugin with the DM send
  # fixed. Upstream addresses DMs as `@<contactId> <text>`, but the daemon
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
  imports = [ inputs.hermes-agent.nixosModules.default ];

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
    # Rebuild rewrites $HERMES_HOME/.env in the activation script, but the
    # long-running hermes process only reads it at startup. sops-nix restarts
    # the unit when this secret's decrypted content changes; the restart runs
    # after activation scripts, so the freshly rendered .env is already on disk.
    files.env.secret = true;
    files.env.restartUnits = [ "hermes-agent.service" ];
    script = ''
      {
        printf 'OPENROUTER_API_KEY=%s\n' "$(cat $in/openrouter/apikey)"
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$(cat $prompts/telegram_token)"
        printf 'TELEGRAM_ALLOWED_USERS=%s\n' "$(cat $prompts/telegram_allowed_users)"
      } > $out/env
    '';
  };

  services.hermes-agent = {
    enable = true;
    container.enable = true; # backend defaults to docker
    container.hostUsers = [ "grmpf" ];
    addToSystemPackages = true;
    environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
    settings.model.default = "anthropic/claude-sonnet-4";
    extraPlugins = [ simplexPlatformFixed ];
  };

  # Host CLI talks to the rootful docker socket when routing into the
  # container; hostUsers only grants the hermes group, not docker.
  users.users.grmpf.extraGroups = [ "docker" ];

  # virtualisation.nix (via laptop-dave) sets DOCKER_HOST to the rootless
  # socket session-wide; that steers `docker`/hermes CLI routing at the
  # wrong daemon ("No such container: hermes-agent"). Force it off here —
  # the rootless daemon stays usable via an explicit context/--host.
  virtualisation.docker.rootless.setSocketVariable = lib.mkForce false;
}
