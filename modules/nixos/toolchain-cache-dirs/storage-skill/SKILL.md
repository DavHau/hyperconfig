---
name: storage
description: Where to put files on this machine. Your home is small and backed up, ~/scratch and ~/.cache are large and not. Read before downloading datasets or models, writing build output or experiment results, or when a write fails with "Disk quota exceeded" / "No space left on device".
---

# Storage: backed-up home, unbacked scratch

| Path | Backed up (snapshots) | Limit | Check |
|---|---|---|---|
| `~` | yes | 20G, hard | `df -h ~` |
| `~/scratch`, `~/.cache`, `~/.local/share/containers` | no | one larger limit for all of them | `df -h ~/scratch` |

`df` shows your own limit as the size and your usage as used, not the
disk. At the limit, writes fail with `Disk quota exceeded` (or `No space
left on device`); deleting frees the space immediately, snapshots do not
count against you.

If `~/scratch` does not exist, your account has not been switched over
yet: follow the same rules, but do NOT create `~/scratch` yourself (the
switch-over needs it absent or empty).

## What goes where

- `~` (backed up): git repos, notes, configs, code, small results you
  would hate to lose.
- `~/scratch` (not backed up): datasets, downloads, model weights,
  build outputs, checkpoints, logs and large experiment output, clones
  of big third-party repos, anything you can fetch or regenerate.
- `/tmp`: emptied at every reboot, files unused for a day are deleted
  (`/var/tmp`: 30 days). Not for anything you want tomorrow.

Inside a repo in `~`, write large outputs to `~/scratch/<project>/` and
pass that path to the tool (`--output-dir`, `-o`, a config entry), or
symlink the output dir there (below).

## Tool caches already off your home

Set for you, nothing to do (`env | grep -i cache` shows them):

- `~/.cache` by default: pip, uv, Hugging Face (`HF_HOME`), torch,
  playwright, puppeteer, ccache, nix, yarn v1, deno, go build cache.
- Moved there: cargo's build intermediates (`CARGO_BUILD_BUILD_DIR`:
  deps, incremental, build scripts go to `~/.cache/cargo-build/...`,
  deleted once their workspace is gone or after 14 unused days; `./target`
  keeps only the final binaries), Go modules (`GOMODCACHE`), npm
  (`npm_config_cache`), pnpm store (`pnpm_config_store_dir`), bun
  (`BUN_INSTALL_CACHE_DIR`), Gradle (`GRADLE_USER_HOME`, so
  `gradle.properties` lives in `~/.cache/gradle`), Maven repository
  (`MAVEN_OPTS`), ollama models (`OLLAMA_MODELS`), conda packages
  (`CONDA_PKGS_DIRS`).
- Still in `~`: `.venv` and `node_modules` in your repos, final binaries
  in `./target`, and `~/.cargo/registry` (safe to delete; cargo downloads
  it again). Delete them from projects you are done with.

Do not override these variables to point back into `~`.

## Finding and moving big directories

```sh
du -xh -d1 ~ | sort -h | tail     # -x: the backed-up part only
mv ~/big-dir ~/scratch/big-dir && ln -s ~/scratch/big-dir ~/big-dir
```

`mv` across the two copies the data, so it needs room in `~/scratch`
first. Programs keep working through the symlink. Do not symlink a git
repo's `.git` away; move build/data subdirectories instead.

## Never fill a disk

Check `df -h ~ ~/scratch` before a large download or a long run, and
keep below about 80 % of each limit. A full home breaks your own
sessions and tools (git, shells, editors, anything writing under `~`)
until you delete something. If you need more space than your limits
allow, ask the operator instead of working around them.
