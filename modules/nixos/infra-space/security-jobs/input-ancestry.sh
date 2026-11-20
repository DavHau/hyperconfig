# sec-job-input-ancestry NODE OLD-LOCK NEW-LOCK: a movable input's new
# locked rev must be in the history of its tracked ref on the real remote
# (the branch tip or an earlier commit of it) AND descend from its old
# locked rev (a move forward, never a downgrade or a jump to a side
# branch). GitHub serves a fork's objects under the parent's owner/repo,
# so "fetchable by id" proves nothing: only the tracked ref's history
# counts, fetched by ref name. Fails closed on anything it cannot establish.
set -euo pipefail
[ $# = 3 ] || { echo "usage: sec-job-input-ancestry NODE OLD-LOCK NEW-LOCK" >&2; exit 2; }
node=$1
old=$2
new=$3
hex40() {
  case "$1" in *[!0-9a-f]* | "") return 1 ;; esac
  [ ${#1} = 40 ]
}
rev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' "$new")
hex40 "$rev" || { echo "sec-job-guard: FAIL: $node has no full lowercase 40-hex locked rev" >&2; exit 1; }
prev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' "$old")
hex40 "$prev" || { echo "sec-job-guard: FAIL: $node's current locked rev is not 40-hex" >&2; exit 1; }
kind=$(jq -r --arg n "$node" '.nodes[$n].original.type' "$new")
ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // "HEAD"' "$new")
url=$(jq -r --arg n "$node" '.nodes[$n].original.url // ""' "$new")
case "$kind" in
  github) url="https://github.com/$(jq -r --arg n "$node" '.nodes[$n].original.owner' "$new")/$(jq -r --arg n "$node" '.nodes[$n].original.repo' "$new").git" ;;
  git) ;;
  *) echo "sec-job-guard: FAIL: $node: unsupported movable input type $kind" >&2; exit 1 ;;
esac
# test_root: the offline test's local origins' directory; empty here
test_root=@testRoot@
case "$url" in
  https://* | git+https://* | ssh://* | git@*) ;;
  *)
    if [ -z "$test_root" ] || [ "${url#"$test_root"/}" = "$url" ]; then
      echo "sec-job-guard: FAIL: $node: refusing non-remote URL $url" >&2
      exit 1
    fi
    ;;
esac
url=${url#git+}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/repo"
if ! git -C "$tmp/repo" fetch -q "$url" "$ref"; then
  echo "sec-job-guard: FAIL: $node: cannot fetch tracked ref $ref from $url" >&2
  exit 1
fi
tip=$(git -C "$tmp/repo" rev-parse FETCH_HEAD)
if ! git -C "$tmp/repo" cat-file -e "$rev^{commit}" 2>/dev/null ||
  ! git -C "$tmp/repo" merge-base --is-ancestor "$rev" "$tip"; then
  echo "sec-job-guard: FAIL: $node: $rev is not in the history of tracked ref $ref on $url" >&2
  exit 1
fi
if ! git -C "$tmp/repo" cat-file -e "$prev^{commit}" 2>/dev/null ||
  ! git -C "$tmp/repo" merge-base --is-ancestor "$prev" "$rev"; then
  echo "sec-job-guard: FAIL: $node: $rev does not descend from the current lock $prev (a downgrade or a side branch)" >&2
  exit 1
fi
echo "sec-job-guard: ok: $node moves $prev -> $rev along $ref on $url"
