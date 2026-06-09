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
      default: anthropic/claude-opus-4-8:high
    startup:
      quiet: true
      # The onboarding setup wizard re-runs on every launch here: it bumps
      # `setupVersion` on completion, but config.yml is a read-only Nix-store
      # symlink so that write never persists, leaving setupVersion < current
      # forever. It also calls playWelcomeIntro() at the end, replaying the
      # logo animation even though `quiet` is set. Disable it outright.
      setupWizard: false
  '';
  workmux = inputs.llm-agents.packages.${sys}.workmux;
  # workmux reads ~/.config/workmux/config.yaml; point it at omp (`pi`) instead
  # of its built-in default agent (`claude`).
  workmuxConfigFile = pkgs.writeText "workmux-config.yaml" ''
    agent: pi
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
    If the current project does not have a `.jj` directory, initialize it with
    `jj git init --colocate` before proceeding.

    **Exception — inside a `git` worktree (e.g. one created by `workmux`): use
    `git`, not `jj`.** A git worktree is not a jj workspace, and
    `jj git init --colocate` fails inside one (`Cannot create a colocated jj
    repo inside a Git worktree`). Detect this before touching version control:

    - Run `git rev-parse --git-dir` and `git rev-parse --git-common-dir`. If they
      resolve to **different** directories — the work tree's `.git` is a file
      pointing into `.../.git/worktrees/<name>` — you are in a linked worktree.

    When you are in a linked git worktree:
    - Do **NOT** run `jj git init`, `jj new`, `jj describe`, or any `jj` command.
    - Use `git` for everything: stage with `git add -A`, commit with
      `git commit -m "<summary>"`. The "Mandatory per-task workflow" below does
      **not** apply; your `git` commit is the completion record that replaces
      `jj describe`.
    - Do not hand-merge back to the base branch. Merging/cleanup is done with
      `workmux merge` (or the `/skill:merge` skill); jj re-absorbs the change on
      the main checkout side automatically.

    In the **main checkout** (original repo: `.git` is a directory and
    `git rev-parse --git-dir` equals `--git-common-dir`), keep using `jj` exactly
    as described here. See "Parallel work with workmux" below.

    ### Mandatory per-task workflow

    You **MUST** follow these steps for every task that modifies files. No
    exceptions. The task is **NOT** complete until step 4 is done.

    1. **Before any file write**, run `jj st` and `jj log -r @ --no-graph`.
       - If the current working-copy commit (`@`) has no description AND
         contains changes that are not yours, stop and ask the user.
       - If the current `@` is your previous finished task (has a description
         and committed changes), run `jj new` to start a fresh commit.
       - If the current `@` is empty or already your in-progress work, reuse it.
    2. Make the edits.
    3. Verify the change (build/test as appropriate).
    4. **Before yielding back to the user**, you **MUST** run
       `jj describe -m "<concise summary of what changed>"` on the current
       working-copy commit. This is not optional and not "later" — it is the
       last tool call of the task, after verification, before your final
       message. A task with an undescribed `@` commit is an incomplete task.

    Yielding without running `jj describe` is a contract violation equivalent
    to leaving a TODO in shipped code.

    ### Amending older commits

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

    **NEVER** run `find` on `/` or other large filesystem roots. It will hang or time out. To locate source code or definitions, prefer in order:
    1. `nix eval` (e.g. `nix eval --raw nixpkgs#<pkg>.src` or `nix eval .#nixosConfigurations.<host>.config.<path>`) to resolve store paths or config values.
    2. `git` / `jj` (e.g. `git grep`, `git ls-files`) inside the relevant repo.
    3. `$HOME/projects/<project>` checkouts — clone there if missing and search the source tree directly.

    ## Running Unavailable Programs

    If a program is not currently installed, do NOT attempt to install it via `nix-env` or similar. Instead, use one of:
    - `nix-shell -p <package> --run '<command>'`
    - `nix shell nixpkgs#<package> -c <command>`

    ## Parallel work with workmux

    `workmux` runs multiple agents in parallel, each in its own **git worktree**
    and tmux window. It is installed system-wide and configured to launch omp
    (`pi`) as its agent. Its skills are installed into omp and discoverable.

    Use it when a task splits into independent sub-tasks touching disjoint files,
    or when the user asks to parallelize or delegate work.

    Skills (read on demand via `skill://<name>`, or invoke with `/skill:<name>`):
    - `workmux` — reference for the workmux CLI, config, and concepts.
    - `worktree` — dispatch one or more tasks to fresh worktree agents
      (fire-and-forget). You write prompt files and run `workmux add`; the
      worktree agents do the implementation.
    - `coordinator` — orchestrate worktree agents through their full lifecycle
      (spawn, monitor, send follow-ups, merge).
    - `merge`, `rebase`, `open-pr` — finish work from inside a worktree.

    Core commands:
    - `workmux add <name> -p "<prompt>"` — new worktree + window, launch omp with the prompt.
    - `workmux add <name> -b -P <file>` — background dispatch, prompt read from a file.
    - `workmux status` / `workmux wait` / `workmux capture` / `workmux send` — monitor and talk to agents.
    - `workmux merge [<name>]` — merge the branch and clean up the worktree, window, and branch.

    **Version control inside a worktree is `git`, not `jj`** — see the exception
    under "Version Control" above. A worktree agent implements its task and
    commits with `git`; it must not run `jj`. Do not recursively dispatch more
    worktrees from inside a worktree agent unless the user explicitly asks.

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

      # --- workmux integration ---
      # Make omp discover workmux's skills + status extension, and point
      # workmux's global config at `pi` (its built-in default is `claude`).
      wm_cfg_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/workmux"
      mkdir -p "$config_dir/skills" "$config_dir/extensions" "$wm_cfg_dir"
      for skill in ${workmux}/share/workmux/skills/*/; do
        [ -d "$skill" ] || continue
        ln -sfn "$skill" "$config_dir/skills/$(basename "$skill")"
      done
      ln -sf ${./workmux-status.ts} "$config_dir/extensions/workmux-status.ts"
      ln -sf ${workmuxConfigFile} "$wm_cfg_dir/config.yaml"
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
