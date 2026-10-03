# Delete cargo build dirs (one per workspace, see ../rust-build-cache.nix)
# in which no file changed for CARGO_BUILD_GC_DAYS days. Covers the host
# cache and every sbox project's persisted copy of it.
days="${CARGO_BUILD_GC_DAYS:-14}"
roots=("$HOME/.cache/cargo-build")

state="${XDG_STATE_HOME:-$HOME/.local/state}/sbox/projects"
if [ -d "$state" ]; then
  # Session trees are large and never hold the persisted cache: prune them.
  while IFS= read -r -d '' root; do
    roots+=("$root")
  done < <(find "$state" -type d \( -name sessions -prune -o \
    -path "*/persist$HOME/.cargo/build-dir" -prune -print0 \))
fi

for root in "${roots[@]}"; do
  [ -d "$root" ] || continue
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    # Any file touched within the window (e.g. a running build) keeps it.
    if [ -z "$(find "$dir" -newermt "-${days} days" -print -quit)" ]; then
      echo "removing ${dir%/}"
      rm -rf --one-file-system "${dir%/}"
    fi
  done
done
