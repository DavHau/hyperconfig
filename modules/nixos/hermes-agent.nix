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
{ config, lib, inputs, ... }:
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
    files.env.secret = true;
    script = ''
      printf 'OPENROUTER_API_KEY=%s\n' "$(cat $in/openrouter/apikey)" > $out/env
    '';
  };

  services.hermes-agent = {
    enable = true;
    container.enable = true; # backend defaults to docker
    container.hostUsers = [ "grmpf" ];
    addToSystemPackages = true;
    environmentFiles = [ config.clan.core.vars.generators.hermes-env.files.env.path ];
    settings.model.default = "anthropic/claude-sonnet-4";
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
