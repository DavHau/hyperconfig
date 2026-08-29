# Gateway key for the TeamClaude shared Claude subscription gateway
# (https://teamclaude.p0.contact, project-zero
# modules/nixos/teamclaude-gateway.nix).
#
# This is the client half: a clan var holding the bare gateway key, exported
# into the omp wrappers as TEAMCLAUDE_API_KEY, which is the env var name the
# anthropic provider override in models.yml points at (see omp-common.nix).
#
# `share = true`: one key for the whole clan — the gateway is a single shared
# service. The value lives in project-zero; paste the output of:
#
#   clan vars get pubproxy01 teamclaude-api-key/key   (in project-zero)
#   clan vars generate <machine> --generator teamclaude-api-key
{ config, ... }:
{
  clan.core.vars.generators.teamclaude-api-key = {
    share = true;
    # A persisted prompt IS the file — no generator script, so the var holds
    # exactly the key and nothing else.
    prompts.key = {
      description = "TeamClaude gateway key (project-zero: clan vars get pubproxy01 teamclaude-api-key/key)";
      type = "hidden";
      persist = true;
    };
    # Readable by the desktop user: the omp wrappers run unprivileged and read
    # this at launch. An owner the machine doesn't declare makes
    # sops-install-secrets abort every secret on the host (sops-nix#972).
    files.key = {
      owner = if config.users.users ? grmpf then "grmpf" else "dave";
      mode = "0400";
    };
  };
}
