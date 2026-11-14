# sec-job-protected-check: the evaluation half of sec-job-guard
# (./guard.sh runs it after its path and line checks). Evaluates
# ./protected.nix (what may never change: network, sshd, resolved,
# users, PAM, boot, file systems, nix trust, the protected units' text
# and wantedBy, protected /etc entries, sysctls, activation scripts) on
# every machine of BASE and of HEAD and refuses ANY difference, and a
# HEAD that does not evaluate. It looks at the evaluated configuration,
# not the diff's text, so how an edit is written (nested attrsets,
# `!true`, mkOverride, a new module, a computed name) does not matter.
# Every machine is compared, not only those whose toplevel changes: a
# superset, and cheaper than evaluating each toplevel first.
#
#   sec-job-protected-check BASE HEAD [FLAKE_DIR]
#
# BASE, HEAD: full commit ids in the git repository at FLAKE_DIR
# (default: the current directory). Exit 0 and `protected: no
# difference`, else exit 1 with the first differing paths.

set +e -uo pipefail
protected=@protected@
nixbin=${NIX:-nix}

die() {
  echo "sec-job-protected-check: FAIL: $*" >&2
  exit 1
}
[ $# -ge 2 ] && [ $# -le 3 ] || {
  echo "usage: sec-job-protected-check BASE HEAD [FLAKE_DIR]" >&2
  exit 2
}
base=$1
head=$2
dir=$(cd "${3:-.}" && pwd -P) || die "no directory ${3:-.}"
for r in "$base" "$head"; do
  case "$r" in
    *[!0-9a-f]* | "") die "not a commit id: $r" ;;
  esac
  [ ${#r} = 40 ] || die "not a full commit id: $r"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
apply="cs: ($(cat "$protected")) cs"
# Both revisions at once (each evaluation ~1-4 min, memory ~3-4 GB).
ev() { # side rev
  "$nixbin" --max-jobs 2 --cores 8 eval --json \
    "git+file://$dir?rev=$2#nixosConfigurations" --apply "$apply" \
    >"$tmp/$1.json" 2>"$tmp/$1.err"
}
ev base "$base" &
pid_base=$!
ev head "$head" &
pid_head=$!
wait "$pid_base"
rc_base=$?
wait "$pid_head"
rc_head=$?
if [ "$rc_head" != 0 ]; then
  grep -vE '^(trace|evaluation warning|warning):' "$tmp/head.err" | tail -n 5 >&2
  die "HEAD ($head) does not evaluate"
fi
if [ "$rc_base" != 0 ]; then
  grep -vE '^(trace|evaluation warning|warning):' "$tmp/base.err" | tail -n 5 >&2
  die "BASE ($base) does not evaluate: nothing to compare against"
fi
broken=$(jq -r 'to_entries[] | select(.value == "<eval-error>") | .key' "$tmp/head.json")
[ -z "$broken" ] || die "machine(s) whose protected settings do not evaluate on HEAD: $(echo "$broken" | tr '\n' ' ')"

# The decision: the two documents are equal as JSON, or not (a key
# present on one side only, null against absent, any leaf). The path
# list below only explains it.
if ! jq -e -n --slurpfile a "$tmp/base.json" --slurpfile b "$tmp/head.json" '$a[0] == $b[0]' >/dev/null; then
  diffs=$(jq -n -r --slurpfile a "$tmp/base.json" --slurpfile b "$tmp/head.json" '
    def leaves: paths(type != "object" and type != "array" or length == 0);
    def at($p): try getpath($p) catch "<absent>";
    $a[0] as $x | $b[0] as $y
    | [($x | leaves), ($y | leaves)] | unique
    | map(select(. as $p | ($x | at($p)) != ($y | at($p))))
    | .[] | map(tostring) | join(".")')
  [ -n "$diffs" ] || diffs="(the documents differ; no single leaf shows it)"
  echo "sec-job-protected-check: FAIL: protected settings differ between $base and $head ($(echo "$diffs" | wc -l) paths):" >&2
  echo "$diffs" | head -n 20 | sed 's/^/  /' >&2
  echo "  (sshd, the mesh, pocket-id, the firewall, DNS, users, boot, nix trust and their units: never lock Dave out; a session lands it)" >&2
  exit 1
fi
echo "protected: no difference ($(jq -r 'keys | join(" ")' "$tmp/head.json"))"
