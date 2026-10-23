# Client key for the TeamClaude pooled Claude subscription gateway
# (https://teamclaude.davhau.com, ./teamclaude-gateway on som).
#
# This is the client half: a clan var holding a runtime client key the
# gateway minted, which `teamclaude-api-key` prints. The anthropic provider
# override in models.yml names it as `apiKey: "!teamclaude-api-key"` (see
# omp-common.nix), so every harness resolves the key by running it and no
# wrapper has to export anything. Exit 1 when the var file is unreadable.
#
# `share = true`: one key for the whole clan, booked under one name in
# `teamclaude status`. Mint it on som and paste it here:
#
#   teamclaude-keys add grmpf                       (as root on som)
#   clan vars generate amy --generator teamclaude-api-key --regenerate
{ config, pkgs, ... }:
let
  key = config.clan.core.vars.generators.teamclaude-api-key.files.key;
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

  clan.core.vars.generators.teamclaude-api-key = {
    share = true;
    # A persisted prompt IS the file — no generator script, so the var holds
    # exactly the key and nothing else.
    prompts.key = {
      description = "TeamClaude client key for https://teamclaude.davhau.com (as root on som: teamclaude-keys add <name>)";
      type = "hidden";
      persist = true;
    };
    # Readable by the desktop user: the omp harnesses run unprivileged and
    # read this through `teamclaude-api-key`. An owner the machine doesn't
    # declare makes sops-install-secrets abort every secret on the host
    # (sops-nix#972).
    files.key = {
      owner = if config.users.users ? grmpf then "grmpf" else "dave";
      mode = "0400";
    };
  };
}
