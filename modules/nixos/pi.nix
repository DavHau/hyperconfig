{pkgs, inputs, lib, config, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
  # The whole skill collection from github:mattpocock/skills. omp's skill
  # discovery is non-recursive (skills/<name>/SKILL.md), so the nested
  # upstream taxonomy (skills/<category>/<name>/SKILL.md) is surfaced by
  # pointing skills.customDirectories (see config.yml) at every category
  # directory. Categories are discovered at eval time, so upstream bumps
  # picking up new categories need no edits here. `deprecated` is excluded:
  # upstream marks those as superseded by current skills (design-an-interface
  # -> codebase-design, ubiquitous-language -> domain-modeling) and shipping
  # both would duplicate semantics.
  mattpocockSkillCategories = let
    skillsRoot = "${inputs.mattpocock-skills}/skills";
    entries = builtins.readDir skillsRoot;
    categories = lib.filter
      (name: entries.${name} == "directory" && name != "deprecated")
      (builtins.attrNames entries);
  in map (c: "${skillsRoot}/${c}") categories;
  configFile = common.mkConfigFile mattpocockSkillCategories;
  omp-wrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = common.omp-patched;
    preHook = ''
      config_dir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
      mkdir -p "$config_dir"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${common.agentsFile} "$config_dir/AGENTS.md"
      # Always-apply rules: injected into the system prompt of the main loop
      # AND every subagent (omp forwards rules to subagents, unlike AGENTS.md).
      mkdir -p "$config_dir/rules"
      ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
      # TDD rule split out of default-rules.md so omp-sp (pi-superpowers.nix)
      # can omit it — superpowers ships its own test-driven-development skill.
      ln -sf ${./tdd-rule.md} "$config_dir/rules/tdd-rule.md"
      ln -sf ${./caveman.md} "$config_dir/rules/caveman.md"
      # jobs-hub extension: background-bash-jobs widget + Ctrl+J / /bashjobs
      # overlay; Enter prints a job's log into the chat transcript (native
      # scrollback). /jobs is taken by the builtin printout; source + tests
      # in modules/nixos/jobs-hub/, tests run via bun against the
      # ~/projects/oh-my-pi checkout.
      mkdir -p "$config_dir/extensions"
      ln -sf ${./jobs-hub/jobs-hub.ts} "$config_dir/extensions/jobs-hub.ts"
      # direnv extension: port of Mic92's pi direnv extension — applies
      # `direnv export json` to process.env on session start and after each
      # bash command, so commands run in the devshell without per-command
      # `nix develop -c` re-evals (pair with nix-direnv for cached exports).
      # Source + tests in modules/nixos/direnv/, same bun test setup as
      # jobs-hub. Requires direnv on PATH and an allowed .envrc.
      ln -sf ${./direnv/direnv.ts} "$config_dir/extensions/direnv.ts"
      # spaces MCP server (shared mcpFile): stdio bridge to the per-user
      # spaces-integration-gateway socket. See omp-common.nix for rationale.
      ln -sf ${common.mcpFile} "$config_dir/mcp.json"
      ${lib.optionalString common.models-needed ''ln -sf ${common.modelsFile} "$config_dir/models.yml"''}
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
