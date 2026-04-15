{pkgs, inputs, lib, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  configFile = pkgs.writeText "config.yml" ''
    modelRoles:
      default: anthropic/claude-opus-4-6:medium
  '';
  agentsFile = pkgs.writeText "AGENTS.md" ''
    # Global Agent Instructions

    ## Bash Output

    Do NOT pipe command output through `tail`, `head`, or similar truncation.

    ## Development Style

    Follow Red-Green-Refactor TDD:
    1. **Red**: Write a failing test first that defines the desired behavior.
    2. **Green**: Write the minimal code to make the test pass.
    3. **Refactor**: Clean up the code while keeping all tests green.

    Repeat this cycle for each piece of functionality.

    ## Nix Build Timeout

    Run all `nix build` (and related nix build commands) with a timeout of **120 seconds** by default.
    If a build fails due to a timeout, retry with the timeout doubled (e.g. 120s → 240s → 480s → …).
    Keep doubling on consecutive timeout failures until the build succeeds or fails for a non-timeout reason.

    ## Version Control

    Use `jj` (Jujutsu) instead of `git` for all version control operations.
    If the current project does not have a `.jj` directory, initialize it with `jj git init --colocate` before proceeding.

    When formatting or amending older commits:
    1. `jj new <commit>` to create a new working copy on top of the target commit.
    2. Make the formatting/fix changes.
    3. `jj squash` to fold changes into the parent (the target commit).

    ## Communication Style

    Always use caveman mode (the caveman skill) by default. Speak like caveman while keeping full technical accuracy.
  '';
  omp-wrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = inputs.llm-agents.packages.${sys}.omp;
    preHook = ''
      config_dir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
      mkdir -p "$config_dir/skills/caveman"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${inputs.caveman}/skills/caveman/SKILL.md "$config_dir/skills/caveman/SKILL.md"
      ln -sf ${agentsFile} "$config_dir/AGENTS.md"
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
