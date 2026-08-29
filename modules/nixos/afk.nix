{ pkgs, inputs, lib, config, ... }:
# afk: the omp-based harness from the local ../afk flake checkout, the only omp
# harness on dave's machines. Default package is the non-sandboxed variant
# (private Nix store); afk-nosand is opt-in per host.
#
# afk owns its own profile bootstrap (distribution config.yml via
# $OMP_DISTRO_CONFIG, the jj/isolation rules, the superpowers/direnv
# extensions), so this wrapper only adds what afk does NOT ship:
#
# - the inference endpoint token (INFERENCE_API_KEY, see ./inference-api-key.nix)
#   plus the models.yml referencing it (providers live in omp-common.nix),
# - the spaces MCP server (mcp.json): stdio bridge to the per-user
#   spaces-integration-gateway socket,
# - the host-specific always-apply rule (repo layout) and the top-level
#   AGENTS.md,
# - the jobs-hub extension (background-jobs widget, Ctrl+J / /bashjobs).
#
# NOT deployed here, on purpose: config.yml (afk keeps it user-owned and
# writable so runtime settings persist; defaults arrive via $OMP_DISTRO_CONFIG
# below it) and afk's own extensions/rules (its preHook runs after ours, so
# deploying them here would be an overwrite race).
let
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
in
{
  environment.systemPackages = [
    (inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = inputs.afk.packages.${pkgs.stdenv.hostPlatform.system}.afk;
      preHook = ''
        config_dir="$HOME/.omp/profiles/afk/agent"
        mkdir -p "$config_dir/rules" "$config_dir/extensions" "$config_dir/skills"
        ${common.inferenceApiKeyExport}
        # TeamClaude gateway key export: disabled, see ./omp-common.nix.
        ln -sf ${common.agentsFile} "$config_dir/AGENTS.md"
        # Host-specific always-apply rule (repo layout); the nix/direnv/jj
        # rules live in afk. Rules reach the main loop AND every subagent
        # (omp forwards rules to subagents, unlike AGENTS.md).
        ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
        # Personal skills (see modules/nixos/skills/): symlinked per-skill so
        # user-created skills next to them survive.
        ln -sfn ${./skills/external-scripts} "$config_dir/skills/external-scripts"
        ln -sfn ${./skills/project-init} "$config_dir/skills/project-init"
        # jobs-hub extension: background-bash-jobs widget + Ctrl+J / /bashjobs
        # overlay; Enter prints a job's log into the chat transcript (native
        # scrollback). /jobs is taken by the builtin printout; source + tests
        # in modules/nixos/jobs-hub/.
        ln -sf ${./jobs-hub/jobs-hub.ts} "$config_dir/extensions/jobs-hub.ts"
        # spaces MCP server: stdio bridge to the per-user
        # spaces-integration-gateway socket. See omp-common.nix for rationale.
        ln -sf ${common.mcpFile} "$config_dir/mcp.json"
        ${lib.optionalString common.models-needed ''ln -sf ${common.modelsFile} "$config_dir/models.yml"''}
      '';
    })
  ];
}
