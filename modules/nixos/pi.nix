{pkgs, inputs, lib, config, ...}: let
  sys = pkgs.stdenv.hostPlatform.system;
  llama-swap-enabled = (config.services.llama-swap.enable or false);
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
  llamaSwapProvider = lib.concatStringsSep "\n" [
    "  llama-swap:"
    "    baseUrl: http://127.0.0.1:${toString config.services.llama-swap.port}/v1"
    "    api: openai-completions"
    "    auth: none"
    "    discovery:"
    "      type: lm-studio"
  ];
  modelProviderBlocks =
    lib.optional llama-swap-enabled llamaSwapProvider;
  models-needed = modelProviderBlocks != [ ];
  modelsFile = pkgs.writeText "models.yml"
    (lib.concatStringsSep "\n" ([ "providers:" ] ++ modelProviderBlocks) + "\n");
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
    ${lib.concatMapStringsSep "\n" (dir: "    - ${dir}") mattpocockSkillCategories}
    modelRoles:
      default: claude-fable-5:medium
      # Subagents (`task` tool) run the bundled `task` agent. Default them to the
      # SAME model as the main loop (fable-5); omp's claudeRankingStrategy
      # quota-balances across all logged-in Anthropic accounts automatically.
      # Heavier per-subagent models (e.g. opus-4.8) are opt-in per agent through
      # frontmatter `model:` or `task.agentModelOverrides`. The `task` role does
      # NOT inherit `default`'s thinking suffix, so :medium is explicit.
      task: claude-fable-5:medium
    task:
      isolation:
        # Isolated subagents each run in a copy-on-write snapshot of the repo.
        # `branch` commits each subagent's changes onto a hidden task ref
        # (refs/omp/task/<id>, see the local patch below) — more robust than
        # `patch` for staged-new and binary files, and overlaps surface as real
        # merge conflicts instead of silently dropped hunks. Works in git
        # checkouts (incl. colocated jj) and, via the local
        # omp-jj-workspace-handle.patch, in pure jj workspaces (secondary
        # `jj workspace add` trees, non-colocated repos) — capture goes through
        # jj's backing git store, merges land as described jj commits.
        # autoApply: false (local patch omp-isolation-auto-apply.patch, applies
        # to BOTH the task tool and eval agent()): isolated changes are NOT
        # merged automatically — they stay parked on their task ref and the
        # main loop cherry-picks them against a clean, frozen worktree. The
        # harness's automatic merge races concurrent parent edits and a failed
        # merge corrupts the parent git index (mm HARNESS.md quirks 1/8).
        # Pin overlayfs (auto could otherwise pick reflink/rcopy per host): it
        # mounts the project as a read-only lower layer — zero-copy even for
        # large gitignored data, copy-up only on write — and runs in-process so
        # it works inside the sandbox namespace.
        mode: overlayfs
        merge: branch
        autoApply: false
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
  # Instructions for the TOP-LEVEL agent only. Everything relevant to
  # subagents lives in the always-apply rules (default-rules.md, caveman.md)
  # symlinked into $config_dir/rules/ below: omp strips AGENTS.md from
  # subagent context (task/index.ts filters basename "agents.md"), but
  # forwards rules unfiltered and injects alwaysApply rules into every
  # agent's system prompt — main loop and subagents alike.
  agentsFile = pkgs.writeText "AGENTS.md" ''
    # Global Agent Instructions

    ## Version Control

    You are the top-level agent; the jj workflow below is yours alone
    (subagents run no version control, per the always-apply rules).
    If the current project does not have a `.jj` directory, initialize it with
    `jj git init --colocate` before proceeding.

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

    ## Parallel work with subagents

    For independent sub-tasks touching disjoint files, or when the user asks
    to parallelize: `task` tool, `isolated: true` per file-editing task.
    Subagents run no version control.

    Isolated changes are NOT merged automatically
    (`task.isolation.autoApply: false`): each finished agent parks its
    commits on a git ref `refs/omp/task/<id>` — hidden from jj, and nothing
    will remind you of it later. You merge:

    1. Clean worktree first: `jj describe`, then `jj new` if `@` is non-empty.
    2. `git for-each-ref refs/omp/task` — the authoritative list of pending
       work. Also run this at session start and before the final
       `jj describe`; non-empty output = unmerged work, adopt or discard
       deliberately.
    3. `git cherry-pick $(git merge-base HEAD <ref>)..<ref>`, review, test.
    4. `git update-ref -d <ref>`.

    On conflict: resolve and `git cherry-pick --continue`, or `--abort` and
    extract files via `git show <ref>:<path>`. If the index ends up broken:
    `rm -f .git/index && git read-tree HEAD` (index is derived state; jj and
    worktree untouched).
  '';
  # omp 16.3.5's isolated-task branch merge creates and later deletes a real
  # git branch (refs/heads/omp/task/<id>) in the parent repo. In a COLOCATED
  # jj checkout, any concurrent jj invocation (starship prompt, user command)
  # imports that transient branch; the post-merge deletion then makes jj
  # abandon the commits the branch pinned and auto-rebase the parent's whole
  # stack onto a stale bookmark (e.g. `main` sitting N commits back) —
  # silently orphaning every commit in between even though the merge reported
  # success (mm incident 2026-07-06, HARNESS.md quirk 5). The patch moves
  # task refs to refs/omp/task/* — invisible to jj import, still resolvable
  # via the short `omp/task/<id>` name by every git command. Upstream report:
  # see omp-jj-colocated-task-refs.issue.md next to the patch.
  # omp-isolation-auto-apply.patch adds the `task.isolation.autoApply` setting
  # (default true; we set false above): when disabled, neither the task tool
  # nor eval agent() merges isolated changes back automatically — refs stay
  # parked for the orchestrator-driven merge described in AGENTS.md. An
  # explicit agent(apply=True/False) still overrides per call.
  # omp-vcs-handle-seam.patch (PR-1 of the jj-workspace isolation plan):
  # pure refactor extracting the VCS operations of isolated task execution
  # behind a `VcsHandle` interface (src/task/vcs.ts). No behavior change —
  # git checkouts resolve to the same machinery; the seam is where the
  # jj-workspace handle below plugs in without touching the isolation
  # lifecycle. Upstreamable as a standalone refactor (IS #1597's
  # "VCS-aware, not a jj special-case").
  # omp-jj-workspace-handle.patch (PR-2): JjWorkspaceHandle — isolated
  # subagents work in pure jj workspaces (secondary `jj workspace add`
  # trees, non-colocated repos). Baseline = the `@` commit (jj
  # auto-snapshot); capture/commit via git plumbing against jj's backing
  # store (temp index, hidden refs/omp/task/* refs); merge-back 3-way via
  # `git merge-tree` entirely in-store, landed as a described jj commit —
  # conflicts leave the workspace untouched with the ref parked. The
  # snapshot's `.jj` pointer is stripped before the subagent runs so nothing
  # inside isolation can write through to the shared store.
  omp-patched = inputs.llm-agents.packages.${sys}.omp.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./omp-jj-colocated-task-refs.patch
      ./omp-isolation-auto-apply.patch
      ./omp-vcs-handle-seam.patch
      ./omp-jj-workspace-handle.patch
    ];
  });
  omp-wrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = omp-patched;
    preHook = ''
      config_dir="''${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
      mkdir -p "$config_dir"
      ln -sf ${configFile} "$config_dir/config.yml"
      ln -sf ${agentsFile} "$config_dir/AGENTS.md"
      # Always-apply rules: injected into the system prompt of the main loop
      # AND every subagent (omp forwards rules to subagents, unlike AGENTS.md).
      mkdir -p "$config_dir/rules"
      ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
      ln -sf ${./caveman.md} "$config_dir/rules/caveman.md"
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
