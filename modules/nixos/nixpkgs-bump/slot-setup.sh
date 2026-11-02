# Runs as root in the agent's slot (bash -s, from ./agent-handoff.sh), before
# every hand-off: the login profile hermes' terminal snapshots (the host's
# tool closure on PATH, and the pipeline's build limits for the slot's nix,
# which the host's nix-daemon honours per client), and a fresh clone of the
# pipeline's commit on branch nixpkgs-bump.
#   $1 tools (store path, the slot shares the host's store)
#   $2 max-jobs  $3 cores  $4 hand-off directory  $5 clone path
set -euo pipefail
tools=$1 jobs=$2 cores=$3 handoff=$4 repo=$5

cat >"$HOME/.bash_profile" <<EOF
export PATH=$tools/bin:\$PATH
export NIX_CONFIG="experimental-features = nix-command flakes
max-jobs = $jobs
cores = $cores"
EOF
export PATH=$tools/bin:$PATH

rm -rf "$repo"
mkdir -p "$(dirname "$repo")"
git clone --quiet --no-checkout "$handoff/repo.bundle" "$repo"
cd "$repo"
git remote remove origin
git checkout --quiet -B nixpkgs-bump "$(cat "$handoff/base")"
git config user.name bumper
git config user.email bumper@localhost
echo "slot ready: $repo at $(git rev-parse --short HEAD)"
