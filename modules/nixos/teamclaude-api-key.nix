# Client key for the TeamClaude pooled Claude subscription gateway
# (https://teamclaude.davhau.com, ./teamclaude-gateway on som).
#
# One static key for all of our own infrastructure: a generated shared clan
# var, which `teamclaude-api-key` prints. The anthropic provider override in
# models.yml names it as `apiKey: "!teamclaude-api-key"` (see
# omp-common.nix), so every harness resolves the key by running it and no
# wrapper has to export anything. Exit 1 when the var file is unreadable.
#
# The gateway accepts it declaratively: ./teamclaude-gateway imports this
# module and declares it as the static client key `hyperconfig`
# (hyper.teamclaudeGateway.clientKeys; usage is booked under that name in
# `teamclaude status`). Other people's keys stay runtime-minted there
# (`teamclaude-keys add <name>`). Rotate with
#
#   clan vars generate som --generator teamclaude-api-key --regenerate
#
# and deploy som plus every machine importing this module.
{ config, lib, pkgs, ... }:
let
  key = config.clan.core.vars.generators.teamclaude-api-key.files.key;
  owner = if config.users.users ? grmpf then "grmpf" else "dave";
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      runtimeInputs = [ pkgs.coreutils ];
      name = "teamclaude-api-key";
      text = ''
        [ -r ${key.path} ] && exec cat ${key.path}
        echo "teamclaude-api-key: ${key.path} is not readable for $(id -un)" >&2
        exit 1
      '';
    })
  ];

  # Every account that runs a harness reads the key through this group: the
  # desktop user and, where it exists, the fleet `agent` account
  # (./agent-user.nix), which gets afk's models.yml too.
  users.groups.teamclaude-api-key.members = [ owner ] ++ lib.optional (config.users.users ? agent) "agent";

  clan.core.vars.generators.teamclaude-api-key = {
    share = true;
    runtimeInputs = [ pkgs.openssl ];
    # `sk-ant-oat01-` is load-bearing, as for the gateway's operator key:
    # omp presents as Claude Code (the only shape Anthropic accepts
    # subscription OAuth in) only when its key looks like a subscription
    # token, and sends it as `Authorization: Bearer`.
    script = ''
      printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
    '';
    # An owner or group the machine doesn't declare makes sops-install-secrets
    # abort every secret on the host (sops-nix#972).
    files.key = {
      inherit owner;
      group = "teamclaude-api-key";
      mode = "0440";
    };
  };
}
