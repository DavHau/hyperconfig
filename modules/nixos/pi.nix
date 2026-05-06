{pkgs, inputs, lib, config, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  llama-swap-enabled = (config.services.llama-swap.enable or false);
  modelsFile = pkgs.writeText "models.yml" ''
    providers:
      llama-swap:
        baseUrl: http://127.0.0.1:${toString config.services.llama-swap.port}/v1
        api: openai-completions
        auth: none
        discovery:
          type: lm-studio
  '';
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
    If a build fails due to a timeout, retry with the timeout doubled (e.g. 120s \u2192 240s \u2192 480s \u2192 \u2026).
    Keep doubling on consecutive timeout failures until the build succeeds or fails for a non-timeout reason.

    ## Version Control

    Use `jj` (Jujutsu) instead of `git` for all version control operations.
    If the current project does not have a `.jj` directory, initialize it with `jj git init --colocate` before proceeding.

    When formatting or amending older commits:
    1. `jj new <commit>` to create a new working copy on top of the target commit.
    2. Make the formatting/fix changes.
    3. `jj squash` to fold changes into the parent (the target commit).

    ## Dependency Source Code

    When you need to understand how any dependency works, always get its source code rather than guessing or relying on documentation alone.
    1. First check `$HOME/projects/` for an existing checkout of the dependency.
    2. If not found, clone the project into `$HOME/projects/` and read the source there.
    3. Use the source code as the primary reference for understanding behavior, APIs, and internals.

    ## Long-Running Commands

    Run all shell commands with a default timeout of **5 seconds**.
    If a command fails due to a timeout, rerun it using `pueue` with a timeout of **600 seconds**:

    ```bash
    # Add command to pueue
    pueue add -- '<command>'
    # get last 15 lines of log output
    pueue log <task_id>
    # kill command
    pueue kill <task_id>
    # wait for command to finish (returns early if process terminates)
    timeout 60 pueue wait <task_id>
    ```

    **Do NOT** use `sleep N && pueue wait`. Use `timeout N pueue wait <task_id>` instead — it returns immediately when the task finishes rather than always waiting the full sleep duration.

    ## NixOS Module Organization

    Always create new NixOS features as a separate `.nix` file in `modules/nixos/` and import it where needed.
    Do NOT inline new features into existing files.


    ## Nix Store

    **NEVER** run `find` on the top-level `/nix/store` directory. It contains millions of entries and will hang or time out. If you need to locate a file inside a specific store path, use the full store path (e.g. `find /nix/store/<hash>-<name>/`).

    ## Running Unavailable Programs

    If a program is not currently installed, do NOT attempt to install it via `nix-env` or similar. Instead, use one of:
    - `nix-shell -p <package> --run '<command>'`
    - `nix shell nixpkgs#<package> -c <command>`

    ${builtins.readFile ./caveman.md}
  '';
  omp-wrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = inputs.llm-agents.packages.${sys}.omp;
    preHook = ''
      config_dir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
      mkdir -p "$config_dir"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${agentsFile} "$config_dir/AGENTS.md"
      ${lib.optionalString llama-swap-enabled ''ln -sf ${modelsFile} "$config_dir/models.yml"''}
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
