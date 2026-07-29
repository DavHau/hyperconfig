{ pkgs, inputs, lib, config, ... }:
# afk: the omp-based harness from the local ../afk flake checkout — since the
# patched-omp wrappers (pi.nix, pi-superpowers.nix) were dropped, this is the
# ONLY omp harness on dave's machines. Default package is the non-sandboxed
# variant (private Nix store); afk-nosand is deliberately not installed — opt
# in per host if needed.
#
# afk owns its own profile bootstrap (distribution config.yml via
# $OMP_DISTRO_CONFIG, the jj rules, the superpowers/direnv/isolation-guard
# extensions), so this wrapper only adds what afk does NOT ship:
#
# - the inference endpoint token (INFERENCE_API_KEY, see ./inference-api-key.nix)
#   plus the models.yml that actually references it — the fleet inference
#   provider (p0) and the optional llama-swap provider live in omp-common.nix,
# - the spaces MCP server (mcp.json): stdio bridge to the per-user
#   spaces-integration-gateway socket,
# - the host-specific always-apply rules (nix/NixOS facts, caveman) and the
#   top-level jj AGENTS.md,
# - the jobs-hub extension (background-jobs widget, Ctrl+J / /bashjobs).
#
# These were previously deployed into ~/.omp/profiles/afk/agent only as
# leftovers from an older afk.nix, so the symlinks rotted (the live models.yml
# still named the pre-rename `bam-vm` provider). Deploying them here makes the
# profile declarative again.
#
# NOT deployed here, on purpose:
# - config.yml: afk keeps it user-owned and writable so runtime settings
#   writes (model selection, /settings) persist; distribution defaults arrive
#   via $OMP_DISTRO_CONFIG, a layer BELOW it.
# - direnv.ts / superpowers.ts / jj-basics.md / isolated-task-merge.md: afk's
#   own preHook symlinks these, and it runs after ours (outer wrapper first),
#   so deploying them here would just be an overwrite race.
# - tdd-rule.md: superpowers ships its own test-driven-development skill; same
#   reasoning pi-superpowers.nix used to omit it.
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
        mkdir -p "$config_dir/rules" "$config_dir/extensions"
        ${common.inferenceApiKeyExport}
        ln -sf ${common.agentsFile} "$config_dir/AGENTS.md"
        # Always-apply rules: injected into the system prompt of the main loop
        # AND every subagent (omp forwards rules to subagents, unlike AGENTS.md).
        ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
        ln -sf ${./caveman.md} "$config_dir/rules/caveman.md"
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
