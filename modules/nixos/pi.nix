{pkgs, inputs, lib, config, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  llama-swap-enabled = (config.services.llama-swap.enable or false);
  # Selected skills from github:mattpocock/skills, curated into a tree that
  # preserves the upstream engineering/ + productivity/ grouping. omp's skill
  # discovery is non-recursive (skills/<name>/SKILL.md), so the nested upstream
  # taxonomy is surfaced by pointing skills.customDirectories (see config.yml)
  # at each category dir. Includes the three requested skills plus the skill
  # dependencies they invoke via /skill prose (codebase-design, domain-modeling).
  mattpocockSkillsTree = pkgs.linkFarm "mattpocock-skills" (
    let skill = name: { inherit name; path = "${inputs.mattpocock-skills}/skills/${name}"; };
    in map skill [
      "engineering/improve-codebase-architecture"
      "engineering/grill-with-docs"
      "engineering/codebase-design"
      "engineering/domain-modeling"
      "productivity/grilling"
    ]
  );
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
    startup:
      quiet: true
      # The onboarding setup wizard re-runs on every launch here: it bumps
      # `setupVersion` on completion, but config.yml is a read-only Nix-store
      # symlink so that write never persists, leaving setupVersion < current
      # forever. It also calls playWelcomeIntro() at the end, replaying the
      # logo animation even though `quiet` is set. Disable it outright.
      setupWizard: false
    skills:
      customDirectories:
        - ${mattpocockSkillsTree}/engineering
        - ${mattpocockSkillsTree}/productivity
    modelRoles:
      default: claude-fable-5:medium
    task:
      isolation:
        # Isolated subagents (`task` tool, `isolated: true`) each run in a
        # copy-on-write snapshot of the repo; changes are merged back on
        # finish. `patch` applies the diff to the parent working copy, so it
        # lands as ordinary WIP in jj's `@`. Requires a colocated `.git`.
        mode: auto
        merge: patch
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

    ### Mandatory per-task workflow

    You **MUST** follow these steps for every task that modifies files. No
    exceptions. The task is **NOT** complete until step 4 is done.

    1. **Before any file write**, run `jj st` and `jj log -r @ --no-graph`.
       - If the current working-copy commit (`@`) has no description AND
         contains changes that are not yours, stop and ask the user.
       - If the current `@` is your previous finished task (has a description
         and committed changes), run `jj new` to start a fresh commit.
       - If `@` has a description (yours or the user's) and you are about to
         make changes **unrelated to that description** (a different logical
         task), run `jj new` first — do not commingle unrelated work into an
         already-described commit.
       - If the current `@` is empty or already your in-progress work on the
         same logical task, reuse it.
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

    **Do NOT** pipe the queued command's output through `tail`, `head`, or similar inside `pueue add` (e.g. `pueue add -- 'cmd 2>&1 | tail -n 25'`). The pipe hides everything but the kept lines from `pueue log`, breaks the exit status (pueue sees the pipe's status, not the command's), and buys nothing — `pueue log` already truncates. Queue the bare command; page its output later with `pueue log <task_id>`.

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

    ## Parallel work with subagents

    For independent sub-tasks touching disjoint files, or when the user asks to
    parallelize: use the built-in `task` tool with `isolated: true` per task.
    Each isolated subagent runs in its own copy-on-write snapshot of the repo;
    its changes are merged back automatically when it finishes. Monitor with
    the `job` tool, message running agents with `irc`, read results via
    `agent://<id>`.

    Merged changes land as ordinary working-copy edits in `@` — describe them
    with the normal jj workflow above. Isolation requires a colocated git
    checkout (`jj git init --colocate`); do not run git worktree commands.

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
