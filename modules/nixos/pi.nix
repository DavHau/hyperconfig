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
      "engineering/diagnosing-bugs"
      "engineering/improve-codebase-architecture"
      "engineering/grill-with-docs"
      "engineering/tdd"
      "engineering/codebase-design"
      "engineering/domain-modeling"
      "productivity/grilling"
    ]
  );
  dual = config.services.omp-dual-anthropic;
  dual-enabled = dual.enable;
  # One anthropic-messages custom provider per account gateway. This is
  # api: anthropic-messages, NOT transport: pi-native — a pi-native client
  # sends `<providerId>/<model>` as the model id, which the gateway keys only
  # as `anthropic/<model>` (and bare `<model>`), so a renamed provider 404s.
  # The anthropic client instead sends the bare model id to baseUrl/v1/messages;
  # the gateway resolves it and dispatches with this account's single OAuth
  # credential, adding the Claude-Code OAuth prefix the client omits. apiKey is
  # the gateway bearer token at the profile's config root (see omp-dual-anthropic.nix).
  mkGatewayProvider = acct: lib.concatStringsSep "\n" [
    "  ${acct.providerId}:"
    "    baseUrl: http://127.0.0.1:${toString acct.gatewayPort}"
    "    api: anthropic-messages"
    "    authHeader: true"
    "    disableStrictTools: true"
    "    apiKey: '!cat \"$HOME/.omp/profiles/${acct.profile}/auth-gateway.token\"'"
    "    models:"
    "      - id: ${acct.model}"
  ];
  llamaSwapProvider = lib.concatStringsSep "\n" [
    "  llama-swap:"
    "    baseUrl: http://127.0.0.1:${toString config.services.llama-swap.port}/v1"
    "    api: openai-completions"
    "    auth: none"
    "    discovery:"
    "      type: lm-studio"
  ];
  modelProviderBlocks =
    lib.optional dual-enabled (mkGatewayProvider dual.mainAccount)
    ++ lib.optional dual-enabled (mkGatewayProvider dual.subAccount)
    ++ lib.optional llama-swap-enabled llamaSwapProvider;
  models-needed = modelProviderBlocks != [ ];
  modelsFile = pkgs.writeText "models.yml"
    (lib.concatStringsSep "\n" ([ "providers:" ] ++ modelProviderBlocks) + "\n");
  # Dual-account model roles: main loop -> account 1's fable-5, subagents ->
  # account 2's opus-4.8. Falls back to the single built-in anthropic provider
  # when the dual-account services are disabled.
  defaultRole = if dual-enabled then "${dual.mainAccount.providerId}/${dual.mainAccount.model}:medium" else "claude-fable-5:medium";
  taskRole = if dual-enabled then "${dual.mainAccount.providerId}/${dual.mainAccount.model}:medium" else "claude-fable-5:medium";
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
      default: ${defaultRole}
      # Subagents (`task` tool) run the bundled `task` agent. Default them to the
      # SAME account/model as the main loop (account 1's fable-5). Heavier
      # per-subagent models (e.g. account 2's opus via anthropic-sub) are opt-in
      # per agent through frontmatter `model:` or `task.agentModelOverrides`. The
      # `task` role does NOT inherit `default`'s thinking suffix, so :medium is explicit.
      task: ${taskRole}
    task:
      isolation:
        # Isolated subagents (`task` tool, `isolated: true`) each run in a
        # copy-on-write snapshot of the repo; changes are merged back on
        # finish. `branch` commits each subagent's changes onto a task branch
        # and cherry-picks them onto the parent HEAD — more robust than `patch`
        # for staged-new and binary files, and overlaps surface as real merge
        # conflicts instead of silently dropped hunks. Requires a colocated
        # `.git`.
        # Pin overlayfs (auto could otherwise pick reflink/rcopy per host): it
        # mounts the project as a read-only lower layer — zero-copy even for
        # large gitignored data, copy-up only on write — and runs in-process so
        # it works inside the sandbox namespace.
        mode: overlayfs
        merge: branch
    bash:
      autoBackground:
        # Auto-convert any non-PTY command still running after 10s into a
        # background job (result auto-delivered on completion; poll/cancel via
        # the `job` tool). omp-native backgrounding runs in-process, so it works
        # inside the sandbox/isolation mounts where an external daemon (pueue)
        # could not spawn. Replaces the former pueue workflow.
        enabled: true
        thresholdMs: 10000
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

    **Isolated subagents run no version control.** When you are an isolated
    `task` subagent (running in a copy-on-write worktree), you MUST NOT run
    `jj` or `git` at all — no `jj st`/`new`/`describe`, no `git
    add`/`commit`/`rm`. Just edit files. The harness snapshots your worktree
    and commits/merges your changes into the parent automatically; running
    version control yourself corrupts that capture. Everything below applies
    to the top-level agent operating directly on the repo working copy.

    ### Mandatory per-task workflow

    You **MUST** follow these steps for every **top-level** task that modifies files. No
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

    Each subagent's changes are committed onto a task branch and cherry-picked
    onto the parent HEAD when it finishes (branch merge mode), so they arrive as
    ready-made commits rather than loose WIP — describe your own remaining work
    with the normal jj workflow above. The subagents themselves run no version
    control. Isolation requires a colocated git checkout (`jj git init
    --colocate`); do not run git worktree commands yourself.

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
      ${lib.optionalString models-needed ''ln -sf ${modelsFile} "$config_dir/models.yml"''}
    '';
  };
in {
  environment.systemPackages = [
    inputs.llm-agents.packages.${sys}.pi
    omp-wrapped
  ]
  ++ (lib.attrValues inputs.mics-skills.packages.${sys});
}
