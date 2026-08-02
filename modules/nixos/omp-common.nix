# Shared building blocks for the afk harness wrapper (afk.nix): the jj
# AGENTS.md, the spaces MCP server config, the inference-endpoint token
# export, and the models.yml providers (fleet inference + optional
# llama-swap). Imported as a plain function, NOT a NixOS module.
#
# The locally-patched omp package and the generated config.yml used to live
# here too, for the pi.nix / pi-superpowers.nix wrappers. Both wrappers are
# gone: afk is the only omp harness now, it carries its own (already rebased)
# patch set, and it keeps config.yml user-owned with distribution defaults
# layered underneath via $OMP_DISTRO_CONFIG.
{pkgs, lib, config, ...}: let
  llama-swap-enabled = (config.services.llama-swap.enable or false);
  llamaSwapProvider = lib.concatStringsSep "\n" [
    "  llama-swap:"
    "    baseUrl: http://127.0.0.1:${toString config.services.llama-swap.port}/v1"
    "    api: openai-completions"
    "    auth: none"
    "    discovery:"
    "      type: lm-studio"
  ];
  # Inference VM on bam (vLLM behind the guest's nginx, so off-site works).
  # Model ids come from discovery; the token is enforced by nginx on /v1/*.
  # Setup docs: project-zero machines/inference/omp-quickstart.md.
  #
  # modelOverrides is the one place ids appear, and it does two jobs.
  #
  # 1. A thinking toggle: /v1/models advertises no capability, so discovery
  #    stamps `reasoning: false` and omp then sends no thinking param at all,
  #    leaving the Qwen template's `enable_thinking: true` default on with no
  #    way off. qwen-chat-template is the dialect vLLM honours
  #    (chat_template_kwargs); top-level `enable_thinking` is silently ignored.
  #
  # 2. Reserving the output budget inside the context window. vLLM rejects any
  #    request where prompt + max_tokens > --max-model-len (262144 there) with a
  #    hard 400, and omp treats contextWindow and maxTokens as independent: with
  #    the discovered 262144/64000 pair every request above 198144 prompt tokens
  #    400s, so a long session dies outright instead of compacting. Declaring
  #    220K + 32K keeps the sum at 258048 (4096 margin) and puts the ceiling
  #    back under omp's own compaction trigger; 32K out is ~30x the largest
  #    single turn measured on this model.
  #
  # NOT here, deliberately: any thinking-history workaround. The Qwen3.6
  # template used to emit an EMPTY `<think></think>` for every historical
  # assistant turn a client didn't send `reasoning_content` for, which ended
  # agent sessions mid-task. That is fixed once, server-side, in the template
  # the engine serves (project-zero decisions/0020) — no client opts in.
  #
  # Both ids carry the block: `default` is the alias the fleet autopilot runs
  # on. A checkpoint swap to a non-Qwen model must revisit BOTH entries, and a
  # --max-model-len change must revisit the 220K/32K split.
  p0ModelOverride = id: [
    "      ${id}:"
    "        reasoning: true"
    "        contextWindow: 225280"
    "        maxTokens: 32768"
    "        compat:"
    "          thinkingFormat: qwen-chat-template"
  ];
  p0Provider = lib.concatStringsSep "\n" ([
    "  p0:"
    "    baseUrl: https://inference.p0.contact/v1"
    "    api: openai-completions"
    # env var NAME omp reads, never the token (inferenceApiKeyExport fills it)
    "    apiKey: INFERENCE_API_KEY"
    "    discovery:"
    "      type: openai-models-list"
    "    modelOverrides:"
  ]
  ++ p0ModelOverride "Qwen3.6-27B-FP8"
  ++ p0ModelOverride "default");
  modelProviderBlocks =
    lib.optional llama-swap-enabled llamaSwapProvider
    ++ [ p0Provider ];
in rec {
  # Token into the env, never into a config file or the Nix store. Guarded on
  # readability so a machine without `clan vars generate` still launches (that
  # provider just 401s).
  inferenceApiKeyExport = ''
    if [ -r ${config.clan.core.vars.generators.inference-api-key.files.token.path} ]; then
      INFERENCE_API_KEY="$(cat ${config.clan.core.vars.generators.inference-api-key.files.token.path})"
      export INFERENCE_API_KEY
    fi
  '';
  models-needed = modelProviderBlocks != [ ];
  modelsFile = pkgs.writeText "models.yml"
    (lib.concatStringsSep "\n" ([ "providers:" ] ++ modelProviderBlocks) + "\n");
  # Shared MCP servers (symlinked to $config_dir/mcp.json).
  # `spaces` reaches the always-on per-user spaces-integration-gateway --user
  # service (socket $XDG_RUNTIME_DIR/spaces-integration-gateway.sock, 0700 and
  # owner-only) through the stdio<->socket bridge `spaces-mcp-connect` — on PATH
  # from inputs.spaces.nixosModules.spaces-integration-gateway (default-enabled
  # via services.pi-chat). omp runs as the human user, so it connects to the
  # owner-only socket directly; OMP expands ${XDG_RUNTIME_DIR} at discovery time.
  mcpFile = pkgs.writeText "mcp.json" (builtins.toJSON {
    "$schema" = "https://raw.githubusercontent.com/can1357/oh-my-pi/main/packages/coding-agent/src/config/mcp-schema.json";
    mcpServers.spaces = {
      command = "spaces-mcp-connect";
      args = [ "\${XDG_RUNTIME_DIR}/spaces-integration-gateway.sock" ];
    };
  });
  # Instructions for the TOP-LEVEL agent only. Everything relevant to
  # subagents lives in the always-apply rules symlinked into
  # $config_dir/rules/ by afk.nix: omp strips AGENTS.md from
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
    (`task.isolation.apply: false`): each finished agent parks its
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
}
