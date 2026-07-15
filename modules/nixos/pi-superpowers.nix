# omp-sp: a second omp variant wired to obra/superpowers
# (https://github.com/obra/superpowers) instead of the mattpocock skill
# library. Same patched omp binary, same base config (omp-common.nix), but:
#
# - skills.customDirectories points at the superpowers skills/ library
#   (flat skills/<name>/SKILL.md — omp's non-recursive discovery ingests it
#   directly, no per-category fan-out needed),
# - the superpowers extension (modules/nixos/superpowers/) injects the
#   `using-superpowers` bootstrap into the LLM context at session start and
#   after compaction — the piece that makes the skills fire automatically —
#   with an omp/jj tool mapping,
# - minimized system prompt: no caveman.md, no tdd-rule.md (superpowers
#   ships its own TDD methodology); default-rules.md (jj + host-environment
#   facts) and the jj AGENTS.md stay,
# - OMP_PROFILE=sp: fully isolated agent state under ~/.omp/profiles/sp/agent
#   (own sessions, settings, and agent.db — Anthropic accounts need a
#   one-time login under omp-sp).
{pkgs, inputs, lib, config, ...}: let
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
  superpowersSkills = "${inputs.superpowers}/skills";
  configFile = common.mkConfigFile [ superpowersSkills ];
  omp-sp = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = common.omp-patched;
    binName = "omp-sp";
    env = {
      # Named profile: omp derives every user-level path (config, rules,
      # extensions, sessions, agent.db) from ~/.omp/profiles/sp/agent.
      OMP_PROFILE = "sp";
      # Consumed by the superpowers extension to locate
      # using-superpowers/SKILL.md for the bootstrap injection.
      OMP_SUPERPOWERS_DIR = superpowersSkills;
    };
    # The symlink join re-exposes the unwrapped package binary as bin/omp,
    # which would collide with pi.nix's wrapped bin/omp in systemPackages.
    filesToExclude = [ "bin/omp" ];
    preHook = ''
      config_dir="$HOME/.omp/profiles/sp/agent"
      mkdir -p "$config_dir"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${common.agentsFile} "$config_dir/AGENTS.md"
      # Always-apply rules (main loop + every subagent). Only the jj +
      # host-environment rules: superpowers covers methodology (TDD etc.).
      mkdir -p "$config_dir/rules"
      ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
      # Same extensions as pi.nix (jobs-hub, direnv) plus the superpowers
      # bootstrap injector.
      mkdir -p "$config_dir/extensions"
      ln -sf ${./jobs-hub/jobs-hub.ts} "$config_dir/extensions/jobs-hub.ts"
      ln -sf ${./direnv/direnv.ts} "$config_dir/extensions/direnv.ts"
      ln -sf ${./superpowers/superpowers.ts} "$config_dir/extensions/superpowers.ts"
      # spaces MCP server (shared mcpFile): stdio bridge to the per-user
      # spaces-integration-gateway socket. See omp-common.nix for rationale.
      ln -sf ${common.mcpFile} "$config_dir/mcp.json"
      ${lib.optionalString common.models-needed ''ln -sf ${common.modelsFile} "$config_dir/models.yml"''}
    '';
  };
in {
  environment.systemPackages = [ omp-sp ];
}
