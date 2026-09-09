# Per-user setup for bare omp (see omp-p0.nix). $MODELS_FILE is the store
# models.yml; $DEFAULT_MODEL the seed-once role value.
agent="$HOME/.omp/agent"
mkdir -p "$agent"

# models.yml: ours unless the user wrote one. A link into the store is ours
# from an earlier generation.
f="$agent/models.yml"
if [ ! -e "$f" ] || [ "$(readlink -f "$f" 2>/dev/null | cut -d/ -f1-3)" = /nix/store ]; then
  ln -sfn "$MODELS_FILE" "$f"
fi

# Default model, seeded ONCE. Without a saved default omp falls back to the
# first discovered model, which is whatever the endpoint lists first
# (minicpm). config.yml is omp's own writable file: append the role only
# while the file carries no modelRoles at all, so a later Ctrl+P choice or
# a hand edit is never overwritten.
c="$agent/config.yml"
if [ ! -e "$c" ] || ! grep -q '^modelRoles:' "$c"; then
  # omp writes the file without a trailing newline; a bare append would
  # glue the key onto the last line and break the YAML.
  if [ -s "$c" ] && [ "$(tail -c1 "$c")" != "" ]; then
    echo >> "$c"
  fi
  printf 'modelRoles:\n  default: %s\n' "$DEFAULT_MODEL" >> "$c"
fi
