---
name: storage
description: Where to put files on this machine. Your home is small and backed up, ~/scratch and ~/.cache are large and not. Read before downloading datasets, models, SDKs or toolchains, writing build output or experiment runs, or when a write fails with "Disk quota exceeded" / "No space left on device".
---

# Storage: backed-up home, unbacked scratch

| Path | Backed up | Limit | Check |
|---|---|---|---|
| `~` | yes | per account, hard: see `df -h ~` | `df -h ~` |
| `~/scratch`, `~/.cache`, `~/.local/share/containers` | no | one larger limit for all of them | `df -h ~/scratch` |

`df` shows your own limit as the size and your usage as used, not the
disk. At the limit, writes fail with `Disk quota exceeded` (or `No space
left on device`); deleting frees the space immediately. Snapshots do not
count against your limit, but whatever you write to `~` stays on disk
in them for up to four weeks after you delete it: rewriting big files in
`~` (build trees, emulator images, run output) costs disk long after.

If `~/scratch` does not exist, your account has not been switched over
yet: follow the same rules, but do NOT create `~/scratch` yourself (the
switch-over needs it absent or empty).

## What goes where

- `~` (backed up): git repos, notes, configs, code, small results you
  would hate to lose. Nothing a script or a download can recreate. On som
  your agent's state (sessions, memories, skills) is backed up nightly
  too, encrypted, to the fleet's nas.
- `~/scratch` (not backed up): everything rebuildable, in particular:
  - **SDKs and toolchains**: Android SDK/NDK, JDKs, clang/gcc
    toolchains, prebuilt compilers: `~/scratch/<project>/tools/`, one
    copy per version, shared by your experiments.
  - **Emulators and AVDs**: Android AVDs (`~/.android/avd`), emulator
    homes, VM/qemu disk images.
  - **Build output**: kernel `out*/` trees (`O=~/scratch/...`),
    cmake/meson build dirs, `dist/`, images you can rebuild.
  - **Downloaded browsers**: `~/.agent-browser` and other headless
    browser downloads.
  - **Run and experiment dirs**: replays, sweeps, benchmark and
    training output, logs, checkpoints, datasets, model weights,
    clones of big third-party repos.
  For tools with a fixed default path in `~` (`~/.android/avd`,
  `~/.agent-browser`), move the directory and leave a symlink (below).
- `~/.cache` (not backed up): tool caches (set for you, below).
- `/tmp`: emptied at every reboot, files unused for a day are deleted
  (`/var/tmp`: 30 days). Not for anything you want tomorrow, and not
  for bulk data.
- Hermes agents: **never bulk data in your `HERMES_HOME`**
  (`~/.hermes` or `/var/lib/hermes/<you>/state/.hermes`, including its
  `cache/scratch`): that is the agent's state on the system disk,
  outside your limits. Entries in its `cache/scratch` and
  `browser_screenshots` (profiles' too) are deleted after 14 unused days.

Inside a repo in `~`, write large outputs to `~/scratch/<project>/` and
pass that path to the tool (`--output-dir`, `-o`, `O=`, a config
entry), or symlink the output dir there (below).

## Runs and build dirs: clean up after yourself

- **Delete finished runs.** Once a run's result is recorded (numbers in
  your notes, the artifact you keep copied to `~`), delete its run dir.
  Keep at most the ~20 most recent runs per project plus the ones you
  named as keepers; prune before starting a new batch, not when the
  disk is full.
- **One cargo target dir per project, not per commit.** Builds of many
  commits or worktrees of one crate share
  `CARGO_TARGET_DIR=~/scratch/<project>/target` (cargo locks it; builds
  take turns), never a fresh `target-<commit>` per build.

## Tool caches already off your home

Set for you, nothing to do (`env | grep -i cache` shows them):

- `~/.cache` by default: pip, uv, Hugging Face (`HF_HOME`), torch,
  playwright, puppeteer, ccache, nix, yarn v1, deno, go build cache,
  sccache (`SCCACHE_CACHE_SIZE` caps it, old entries are evicted; do
  not raise it).
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
mkdir -p ~/scratch/proj && mv ~/proj/out ~/scratch/proj/out && ln -s ~/scratch/proj/out ~/proj/out
```

Keep the same relative path under `~/scratch` so you find it again.
Stop builds, emulators and servers using the directory first. `mv`
across the two copies the data, so it needs room in `~/scratch` first.
Programs keep working through the symlink. Do not symlink a git repo's
`.git` away; move build/data subdirectories instead.

## Weekly self-check

Once a week, and before a big download or a long batch:

```sh
df -h ~ ~/scratch ~/.cache
du -xh -d2 ~ 2>/dev/null | sort -h | tail -15
du -h -d2 ~/scratch ~/.cache 2>/dev/null | sort -h | tail -15
# dirs over 1G untouched for 7 days: finished runs? delete them
find ~/scratch -mindepth 1 -maxdepth 3 -type d -mtime +7 \
  -exec du -s --block-size=1G {} + 2>/dev/null | awk '$1 >= 1' | sort -n
```

Move what is rebuildable out of `~`, delete finished runs, and ask the
operator only about data you can't judge yourself.

## Never fill a disk

Check `df -h ~ ~/scratch` before a large download or a long run, and
keep below about 80 % of each limit. A full home breaks your own
sessions and tools (git, shells, editors, anything writing under `~`)
until you delete something. If you need more space than your limits
allow, ask the operator instead of working around them.
