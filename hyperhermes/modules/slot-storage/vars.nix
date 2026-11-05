# Where common tools put their churn: under ~/.cache, which a slot keeps
# on scratch. A copy of hyperconfig's modules/nixos/toolchain-cache-dirs/vars.nix
# (this flake is consumed on its own and cannot reach that file; keep the
# two in step). Tools that already default into ~/.cache (cargo's
# build-dir and sccache, pip, uv, Hugging Face, torch, playwright, ccache,
# nix) are not listed.
{
  GOMODCACHE = "$HOME/.cache/go-mod";
  npm_config_cache = "$HOME/.cache/npm";
  pnpm_config_store_dir = "$HOME/.cache/pnpm/store";
  BUN_INSTALL_CACHE_DIR = "$HOME/.cache/bun/install";
  GRADLE_USER_HOME = "$HOME/.cache/gradle";
  MAVEN_OPTS = "-Dmaven.repo.local=$HOME/.cache/maven/repository";
  OLLAMA_MODELS = "$HOME/.cache/ollama/models";
  CONDA_PKGS_DIRS = "$HOME/.cache/conda/pkgs";
}
