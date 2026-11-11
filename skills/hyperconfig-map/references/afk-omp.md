# afk / omp (coding harness) config

- `modules/nixos/afk.nix`: afk wrapper for every machine importing it
  (via `dave.nix`; in spaces via `spaces/afk.nix`). Header explains layers:
  - `hyper.afk.defaultModel` (default `anthropic/claude-opus-5-5:medium`):
    patched into afk's **distro config** (`OMP_DISTRO_CONFIG`, lowest
    layer, `modelRoles.default`) in a copy of the afk package
    (`afkWithDefaultModel`, yq over both distro-config*.yml). User
    config.yml and `/model` override it. Not settable from a preHook
    (afk's wrapper exports OMP_DISTRO_CONFIG after it).
  - `hyper.afk.pinnedSettings`: omp overlay via `PI_CONFIG_FILES`, ABOVE
    the user's config.yml (forced; spaces turn web tools off with it).
  - `hyper.afk.extraSkills.<name> = ./dir`: skill dirs linked into
    `~/.omp/profiles/afk/agent/skills/` (forge-prs in spaces).
  - preHook links AGENTS.md (`omp-common.nix` agentsFile) and
    `default-rules.md` (rules reach subagents; AGENTS.md doesn't).
- `modules/nixos/omp-common.nix`: models.yml (p0 provider, TeamClaude
  override), AGENTS.md text. `omp-p0.nix`: bare omp. `omp-joy.nix`: joy.
- Upstream: input `afk` (flake.nix, pinned rev); its source: `nix flake
  metadata` / `nix eval --raw .#inputs.afk.outPath` (or the store path).
- User state: `~/.omp/profiles/afk/agent/` (config.yml, sessions/).
- Model ids: copy from a working user config (amy
  `~/.omp/profiles/afk/agent/config.yml`).
