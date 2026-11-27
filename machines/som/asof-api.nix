# The data API of slot asof (asofd on port 8410) for som's hermes agents
# that read /vault/parquet: every agent in vault-ro (./hermes-agents-data.nix
# without `vault = false`) gets the slot's `asof` CLI (query, status,
# docs --print, coverage; sandboxed) and the data-api skill
# (./asof-api-skill), through ../../modules/nixos/slot-api-clients.
#
# Per-agent tokens (`api.enable`) stay off until asofd reads the hash file
# this puts into the slot (/var/lib/container-slot/managed/api-clients,
# lines `<agent> <sha256 hex of the token>`) and gives those clients a
# read-only scope: today asofd knows one shared full-rights token, and its
# API has write endpoints (verification records, capture deletion,
# starting resyncs) that agents must not reach. The project tracks that
# change in its own task list (asof-agents slot). Once it is deployed
# there: set `api.enable = true`, generate the generators asof-api-<agent>
# (prompt-free), deploy som. That restarts each listed agent once (new
# credential), not the slot or asofd.
{ lib, ... }:
let
  data = import ./hermes-agents-data.nix;
  vaultReaders = lib.attrNames (lib.filterAttrs (_: a: a.vault or true) data);
in
{
  imports = [ ../../modules/nixos/slot-api-clients ];

  hyper.slotApiClients.asof = {
    slot = "asof";
    port = 8410;
    agents = vaultReaders;
    envPrefix = "ASOF";
    api.enable = false;
    cli = {
      bin = "asof";
      subcommands = [
        "query"
        "status"
        "docs"
        "coverage"
      ];
      # --token: argv is public on som. The rest write files.
      refusedFlags = [
        "--token"
        "--out"
        "--data-root"
        "--write-doc"
        "--check-doc"
      ];
      readPaths = [ "/vault/parquet" ];
      inputFlags = [ "--policy" ];
      urlEnv = "ASOF_URL";
    };
    skill = {
      name = "data-api";
      file = ./asof-api-skill/SKILL.md;
      apiOn = ''
        ## Live data and its history through the API

        `$ASOF_API_URL` and `$ASOF_API_TOKEN` are set in your environment
        (read-only client token, your own):

            asof query --url "$ASOF_API_URL" --as-of now \
              --dataset <group>.<dataset> --limit 100 [--symbols A,B]
            asof status          # the service's health (exit 0/1/2)

        `--as-of now` answers from the store plus the newest rows; any
        other instant is a point-in-time view. `--visibility received`
        (when the service received a row) or `available` (default).
      '';
      apiOff = ''
        ## Live data through the API: not yet

        The service's live API needs a client token, and you have none yet
        (read-only client tokens are being added). Until then use `--root`
        above; `asof query --url` and `asof status` answer 401.
      '';
    };
  };
}
