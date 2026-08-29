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
  # modelOverrides now carries exactly one key, because the endpoint publishes
  # the rest itself.
  #
  # `litellm` discovery makes omp read `/model_group/info` off the inference
  # host — a static document the engine generates next to its own
  # --max-model-len (project-zero modules/inference-model-groups.nix). That
  # supplies the context window, the output cap and reasoning support, so the
  # numbers live once, server-side, instead of in every client. Serving that one
  # extra path changes nothing about `/v1/*`; discovery.type only picks how omp
  # LEARNS about models, never how it talks to them (api stays
  # openai-completions). On a 404 omp falls back to `/v1/models` and loses the
  # output reservation — the tell is a 400 partway into a long session.
  #
  # Why the reservation exists at all: vLLM enforces one budget, prompt +
  # max_tokens <= --max-model-len, and rejects violations with a hard 400. omp
  # treats contextWindow and maxTokens as independent, so the undeclared pair
  # (262144 discovered from max_model_len, 64000 sent on the wire) 400s every
  # request above 198144 prompt tokens.
  #
  # thinkingFormat stays a client override because no protocol advertises a
  # thinking dialect: omp infers it from host + model id, and an unrecognised
  # host serving a Qwen id resolves to Alibaba's top-level `enable_thinking`,
  # which vLLM accepts and silently drops. qwen-chat-template is the spelling it
  # honours (chat_template_kwargs).
  #
  # NOT here, deliberately: any thinking-history workaround. The Qwen3.6
  # template used to emit an EMPTY `<think></think>` for every historical
  # assistant turn a client didn't send `reasoning_content` for, which ended
  # agent sessions mid-task. That is fixed once, server-side, in the template
  # the engine serves (project-zero machines/inference/chat-template.md) — no
  # client opts in.
  p0ModelOverride = id: [
    "      ${id}:"
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
    "      type: litellm"
    "    modelOverrides:"
  ]
  ++ p0ModelOverride "Qwen3.8-27B-FP8");
  # TeamClaude: pooled Claude subscription gateway on pubproxy01 (project-zero
  # modules/nixos/teamclaude-gateway.nix, docs/teamclaude-gateway.md).
  #
  # DISABLED 2026-08-29 (user request): the gateway itself has no capacity —
  # a request with a valid key passes nginx, stalls ~120s inside teamclaude and
  # then answers `429 rate_limit_error "Rate limited; retry in 60s"`
  # (reproduced with plain curl, so it is server-side). Re-enable by
  # uncommenting the block below, the `teamclaudeApiKeyExport` in this file, the
  # `${"$"}{common.teamclaudeApiKeyExport}` line in ./afk.nix's preHook and the
  # ./teamclaude-api-key.nix import in ./dave.nix. Until then the builtin
  # anthropic provider keeps talking to api.anthropic.com with the OAuth logins.
  #
  # KEEP when re-enabling — this cost one dead-on-first-turn debugging session:
  #
  # The `headers.x-api-key` line is load-bearing, not a belt-and-braces
  # duplicate of `apiKey`: for a non-OAuth credential on a NON-official base
  # URL, omp sends `Authorization: Bearer <key>` and suppresses its own
  # X-Api-Key (packages/ai/src/providers/anthropic.ts, buildAnthropicHeaders
  # else-branch + shouldSuppressClientApiKey). The gateway's nginx authenticates
  # solely on `map $http_x_api_key` and answers a bearer-only request with an
  # HTML `401 Authorization Required`, which surfaces in the harness as a dead
  # session on the first turn. A caller-supplied x-api-key header is preserved
  # verbatim, so pinning it here is the only way to satisfy the gateway.
  #
  # `apiKey` stays because it registers the config-sourced credential that beats
  # the stored Anthropic OAuth logins (AuthStorage #configOverrides): without it
  # omp would forward a personal subscription token to the gateway and suppress
  # nothing.
  #
  # Both values are env var NAMES (teamclaudeApiKeyExport fills the var, key
  # from ./teamclaude-api-key.nix). Beware: omp resolves such a value as
  # env-var-name-or-LITERAL (config/model-config-values.ts resolveConfigValue),
  # so a machine where the var file is missing sends the string
  # "TEAMCLAUDE_API_KEY" as the key and 401s exactly like a wrong key.
  #
  # teamclaudeProvider = lib.concatStringsSep "\n" [
  #   "  anthropic:"
  #   "    baseUrl: https://teamclaude.p0.contact"
  #   "    apiKey: TEAMCLAUDE_API_KEY"
  #   "    headers:"
  #   "      x-api-key: TEAMCLAUDE_API_KEY"
  # ];
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
  # Disabled with the provider block above; the interpolation would reference
  # config.clan.core.vars.generators.teamclaude-api-key, which does not exist
  # while ./teamclaude-api-key.nix is not imported in ./dave.nix.
  # teamclaudeApiKeyExport = ''
  #   if [ -r /run/secrets/vars/teamclaude-api-key/key ]; then
  #     TEAMCLAUDE_API_KEY="$(cat /run/secrets/vars/teamclaude-api-key/key)"
  #     export TEAMCLAUDE_API_KEY
  #   fi
  # '';
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
