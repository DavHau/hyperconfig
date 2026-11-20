# sec-job-push JOB COMMIT: privileged side of a security job's landing.
# Runs as infra through its exact sudo rule. COMMIT comes from a bundle at
# the fixed, shared spool path, never from the job's mutable working copy.
set -euo pipefail

jobs=" @jobs@ "
spool=@spool@
origin=@origin@
scratch_root=@scratchRoot@
guard=@guard@

fail() { echo "sec-job-push: FAIL: $*" >&2; exit 1; }
[ $# = 2 ] || fail "usage: sec-job-push cve-watch|hygiene-report|security-audit <40-hex-commit>"
job=$1
rev=$2
case "$jobs" in *" $job "*) ;; *) fail "unknown job: $job" ;; esac
case "$rev" in *[!0-9a-f]* | "") fail "commit id must be lowercase hex" ;; esac
[ ${#rev} = 40 ] || fail "commit id must be full 40-hex"
bundle=$spool/$job-$rev.bundle
[ -f "$bundle" ] && [ ! -L "$bundle" ] || fail "no regular bundle $bundle"

umask 077
mkdir -p "$scratch_root"
scratch=$(mktemp -d "$scratch_root/$job.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/repo"
cd "$scratch/repo"
git remote add origin "$origin"
git fetch -q origin refs/heads/main:refs/remotes/origin/main
base=$(git rev-parse refs/remotes/origin/main)
git fetch -q "$bundle" "$rev"
[ "$(git rev-parse "$rev^{commit}")" = "$rev" ] || fail "$rev is not a commit in $bundle"
git merge-base --is-ancestor "$base" "$rev" || fail "$rev does not descend from origin/main ($base)"
[ "$base" != "$rev" ] || fail "$rev is already origin/main"
git switch -q --detach "$rev"
# The deployed main's guard, not anything in the candidate commit.
"$guard" --commits "$base" "$rev"
git push origin "$rev:refs/heads/main"
echo "sec-job-push: pushed $rev to main"
