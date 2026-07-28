# Bearer token for the fleet inference endpoint (https://inference.p0.contact).
#
# The endpoint enforces it on every /v1/* request (project-zero
# modules/inference-api-key.nix). This is the client half: a clan var holding
# the bare token, exported into the omp wrappers as INFERENCE_API_KEY, which is
# the env var name models.yml points at (see omp-common.nix).
#
# `share = true`: one token for the whole clan, entered once — the endpoint is
# a single shared service, not per-machine state. It lives in a different clan
# than the server, so the value is prompted here as well; paste the same string
# you gave project-zero:
#
#   clan vars generate <machine> --generator inference-api-key
#   clan vars get <machine> inference-api-key/token
{ ... }:
{
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
    # this at launch. 0400 owner-only, never group- or world-readable.
    files.token = {
      owner = "grmpf";
      mode = "0400";
    };
  };
}
