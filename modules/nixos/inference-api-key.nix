# Bearer token for the fleet inference endpoint (https://inference.p0.contact).
#
# The endpoint enforces it on every /v1/* request (project-zero
# modules/inference-api-key.nix). This is the client half: a clan var holding
# the bare token, exported into the omp wrappers as P0_API_KEY, which is
# the env var name models.yml points at (see omp-common.nix).
#
# `share = true`: one token for the whole clan, entered once — the endpoint is
# a single shared service, not per-machine state. It lives in a different clan
# than the server, so the value is prompted here as well; paste the same string
# you gave project-zero:
#
#   clan vars generate <machine> --generator inference-api-key
#   clan vars get <machine> inference-api-key/token
#
# The var file belongs to the desktop user. Any other account that runs
# the omp wrapper gets its own copy: `hyper.inferenceApiKey.users` runs a
# root oneshot per user that installs the token 0400 under
# /run/inference-api-key/<user>/token (re-run on rotation via
# restartUnits). The wrapper's export (omp-common.nix) tries that path
# before the var file.
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.inferenceApiKey;
  token = config.clan.core.vars.generators.inference-api-key.files.token;
  unit = user: "inference-api-key-${user}";
in
{
  options.hyper.inferenceApiKey = {
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Accounts (besides the var file owner) that get a private copy of the token.";
    };
    userTokenPath = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      default = user: "/run/inference-api-key/${user}/token";
      description = "Where a user's copy lands; omp-common.nix reads it with the runtime user name.";
    };
  };

  config = {
    systemd.services = lib.listToAttrs (
      map (
        user:
        lib.nameValuePair (unit user) {
          description = "inference endpoint token copy for ${user}";
          wantedBy = [ "multi-user.target" ];
          # sops-install-secrets writes the var during activation, before
          # any unit starts; the token file is there once the target runs.
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "inference-api-key/${user}";
            RuntimeDirectoryPreserve = true;
            RuntimeDirectoryMode = "0755";
            ExecStart = "${pkgs.coreutils}/bin/install -m 0400 -o ${user} -g root ${token.path} ${cfg.userTokenPath user}";
          };
        }
      ) cfg.users
    );

    clan.core.vars.generators.inference-api-key = {
      share = true;
      # A persisted prompt IS the file — no generator script, so the var holds
      # exactly the token and nothing else.
      prompts.token = {
        description = "Bearer token for https://inference.p0.contact (same value as project-zero)";
        type = "hidden";
        persist = true;
      };
      # Readable by the desktop user: the omp wrappers run unprivileged and read
      # this at launch. An owner the machine doesn't declare makes
      # sops-install-secrets abort every secret on the host (sops-nix#972).
      files.token = {
        owner = if config.users.users ? grmpf then "grmpf" else "dave";
        mode = "0400";
        restartUnits = map (u: "${unit u}.service") cfg.users;
      };
    };
  };
}
