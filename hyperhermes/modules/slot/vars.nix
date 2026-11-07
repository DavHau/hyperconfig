# Tool-default overrides that move rebuildable downloads into ~/.cache
# (a non-snapshotted scratch dataset on hosts with entity storage, and in
# container slots with storage). Plain data, `$HOME` left for the consumer
# to expand: /etc/set-environment expands it per user, hyperhermes
# substitutes each agent's home, ./default.nix falls back to /scratch.
# The one copy: nixosModules.slot (./default.nix) uses it, and so does
# hyperconfig's modules/nixos/toolchain-cache-dirs.
#
# Only tools whose default is outside ~/.cache are listed. Already under
# ~/.cache by default: go build cache (GOCACHE), pip, uv, yarn v1, deno,
# Hugging Face, torch, playwright, puppeteer, ccache, nix, pnpm's metadata
# cache, sccache and cargo's build-dir (hyperconfig's
# modules/nixos/rust-build-cache.nix).
#
# Deliberately not moved:
# - CARGO_HOME (~/.cargo): also holds bin/ and config.toml, and sbox
#   persists ~/.cargo/{registry,git,build-dir} per project and names the
#   build dir via {cargo-cache-home} (hyperconfig's
#   modules/nixos/rust-build-cache.nix).
# - GOPATH (~/go): GOMODCACHE moves the bulky part (pkg/mod) alone, so
#   `go install` binaries stay in ~/go/bin where existing PATHs expect them.
# - RUSTUP_HOME, STACK_ROOT, JULIA_DEPOT_PATH: installed toolchains that a
#   move would silently orphan.
{
  # https://pkg.go.dev/cmd/go#hdr-Environment_variables
  # (default $GOPATH/pkg/mod).
  GOMODCACHE = "$HOME/.cache/go-mod";

  # https://docs.npmjs.com/cli/v11/using-npm/config#cache (default ~/.npm).
  npm_config_cache = "$HOME/.cache/npm";

  # pnpm >= 11 reads only pnpm_config_* (https://pnpm.io/configuring,
  # "Environment variables"; storeDir default ~/.local/share/pnpm/store).
  # No npm_config_store_dir for pnpm <= 10: npm warns about every unknown
  # npm_config_* key on each run. Across datasets pnpm copies instead of
  # hardlinking (https://pnpm.io/faq), which is the point: node_modules
  # stays with the project, the store off the snapshots.
  pnpm_config_store_dir = "$HOME/.cache/pnpm/store";

  # https://bun.sh/docs/install/cache (default ~/.bun/install/cache).
  BUN_INSTALL_CACHE_DIR = "$HOME/.cache/bun/install";

  # https://docs.gradle.org/current/userguide/directory_layout.html
  # (default ~/.gradle). This moves gradle.properties and init.d as well.
  GRADLE_USER_HOME = "$HOME/.cache/gradle";

  # maven.repo.local overrides settings.xml's localRepository (default
  # ~/.m2/repository); MAVEN_OPTS reaches every Maven version, MAVEN_ARGS
  # only 3.9+ (https://maven.apache.org/configure.html).
  MAVEN_OPTS = "-Dmaven.repo.local=$HOME/.cache/maven/repository";

  # A user's own `ollama serve` (default ~/.ollama/models,
  # https://docs.ollama.com/faq).
  OLLAMA_MODELS = "$HOME/.cache/ollama/models";

  # conda reads every setting from CONDA_<NAME> (pkgs_dirs, default
  # ~/.conda/pkgs for a user install; conda/base/context.py).
  CONDA_PKGS_DIRS = "$HOME/.cache/conda/pkgs";
}
