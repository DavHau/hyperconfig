# nixpkgs-bump-guard: the nightly bump's last check before it pushes
# (../nixpkgs-bump/SKILL.md step 6), run in the bump workspace. Exit 0
# and a last line `nixpkgs-bump-guard: PASS`: the push may go ahead;
# anything else: push nothing, the night failed.
#
# Advisory, not a boundary: the agent holds the deploy key and could push
# without it. It mechanically catches drift and injected edits a long run
# may have picked up: a lock that moved more than nixpkgs, to something
# that is not nixpkgs-unstable, a bump that raced another one, and changes
# to paths or options that decide who gets in or what gets trusted. Its
# denylists are broad on purpose: a legitimate fix they reject is a
# failed night for Dave to look at, not something to edit around.
#
#   nixpkgs-bump-guard [--old-rev-file FILE] [--offline]
#
# FILE (default @logDir@/<workspace dir name>.old-rev) holds the nixpkgs
# rev the run started from (step 2 writes it). --offline skips the network
# checks (GitHub, the prefetch); for ./guard-test.nix only, never in a
# run: it never passes, at best it ends with PASS-OFFLINE and exit 3.

offline=0
old_rev_file=
while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=1 ;;
    --old-rev-file)
      old_rev_file=${2:?--old-rev-file needs a path}
      shift
      ;;
    *)
      echo "usage: nixpkgs-bump-guard [--old-rev-file FILE] [--offline]" >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo "nixpkgs-bump-guard: FAIL: $*" >&2
  echo "nixpkgs-bump-guard: push nothing; report failed" >&2
  exit 1
}
failed=0
fail() {
  echo "nixpkgs-bump-guard: FAIL: $*" >&2
  failed=1
}
ok() { echo "nixpkgs-bump-guard: ok: $*"; }

# Every diff the checks read, with what could hide a change switched off:
# in-tree .gitattributes (`-diff`, `binary`, `diff=<driver>`) and the
# repository's own attributes and config (diff.external, textconv) would
# turn changed lines into "Binary files differ" or a driver's output.
# core.attributesFile only drops the global file; the in-tree ones are
# read regardless, which is what --text (never binary), --no-textconv and
# --no-ext-diff neutralise. Names unquoted (core.quotePath=false), no
# rename detection (a rename is a delete and an add, both checked).
gitd() {
  git -c core.quotePath=false -c core.ignoreCase=false -c diff.external= \
    -c core.attributesFile=/dev/null \
    diff --no-ext-diff --no-textconv --text --no-renames --no-color \
    --no-relative --ignore-submodules=none "$@"
}

# --- where: the bump workspace, never the main checkout
ws=$(pwd -P)
name=$(basename "$ws")
case "$name" in
  hyperconfig-nixpkgs-bump-*) ;;
  *) die "not in a bump workspace (hyperconfig-nixpkgs-bump-*): $ws" ;;
esac
root=$(jj root 2>/dev/null) || die "no jj workspace at $ws"
[ "$(cd "$root" && pwd -P)" = "$ws" ] || die "run it at the workspace root ($root), not $ws"

old_rev_file=${old_rev_file:-@logDir@/$name.old-rev}
[ -r "$old_rev_file" ] || die "no start rev in $old_rev_file (step 2 writes it)"
start_rev=$(tr -d '[:space:]' <"$old_rev_file")
[[ "$start_rev" =~ ^[0-9a-f]{40}$ ]] || die "$old_rev_file holds no rev: $start_rev"

# --- what: @ on top of main@origin (this snapshots the working copy)
base=$(jj log --no-graph -r 'main@origin' -T 'commit_id') || die "no main@origin"
head=$(jj log --no-graph -r '@' -T 'commit_id')
[ -n "$(jj log --no-graph -r 'main@origin & ::@' -T 'commit_id')" ] ||
  die "@ does not descend from main@origin: fetch and rebase first"
[ -z "$(jj log --no-graph -r '(main@origin..@) & conflicts()' -T 'commit_id')" ] ||
  die "conflicted commits between main@origin and @"
[ "$base" != "$head" ] || die "@ is main@origin: nothing to push"
# What gets pushed is @ and what is below it: every commit described.
[ -z "$(jj log --no-graph -r '(main@origin..@) & (empty() | description(exact:""))' -T 'commit_id')" ] ||
  die "an empty or undescribed commit between main@origin and @ (push the last described change: jj edit it, or jj abandon @)"
# Whether main moved on GitHub since the fetch is the push's to say: jj
# refuses a push whose remote bookmark is not main@origin.
ok "@ ($head) on main@origin ($base)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git show "$base:flake.lock" >"$tmp/old.json" || die "no flake.lock on main@origin"
git show "$head:flake.lock" >"$tmp/new.json" || die "no flake.lock in @"

# --- (i) flake.lock: only the root nixpkgs node's `locked` moved
node=$(jq -r '.nodes.root.inputs.nixpkgs | strings' "$tmp/old.json")
node_new=$(jq -r '.nodes.root.inputs.nixpkgs | strings' "$tmp/new.json")
[ -n "$node" ] && [ "$node" = "$node_new" ] ||
  die "flake.lock: root nixpkgs node changed ('$node' -> '$node_new')"
jq -e -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" --arg n "$node" \
  '($a[0] | del(.nodes[$n].locked)) == ($b[0] | del(.nodes[$n].locked))' >/dev/null ||
  fail "flake.lock: more than nixpkgs' locked changed (other nodes, new nodes, or original)"
jq -e --arg n "$node" '.nodes[$n].original ==
    {owner: "NixOS", repo: "nixpkgs", ref: "nixpkgs-unstable", type: "github"}' \
  "$tmp/new.json" >/dev/null ||
  fail "flake.lock: nixpkgs' original is not github:NixOS/nixpkgs/nixpkgs-unstable"
jq -e --arg n "$node" '.nodes[$n].locked as $l
    | ($l | keys) == ["lastModified", "narHash", "owner", "repo", "rev", "type"]
    and $l.owner == "NixOS" and $l.repo == "nixpkgs" and $l.type == "github"
    and ($l.rev | test("^[0-9a-f]{40}$"))
    and ($l.narHash | test("^sha256-[A-Za-z0-9+/]{43}=$"))
    and ($l.lastModified | type) == "number"' \
  "$tmp/new.json" >/dev/null ||
  fail "flake.lock: nixpkgs' locked is not a plain github:NixOS/nixpkgs rev"

locked() { jq -r --arg n "$node" ".nodes[\$n].locked.$2" "$tmp/$1.json"; }
old_rev=$(locked old rev)
new_rev=$(locked new rev)
new_hash=$(locked new narHash)
new_mod=$(locked new lastModified)

# --- (iii) nobody else bumped since the run started
[ "$old_rev" = "$start_rev" ] ||
  die "main@origin's nixpkgs is $old_rev, the run started from $start_rev: someone else bumped"
if [ "$new_rev" = "$old_rev" ]; then
  fail "flake.lock: nixpkgs did not move"
elif [ "$new_mod" -lt "$(locked old lastModified)" ]; then
  fail "flake.lock: lastModified went backwards"
else
  ok "flake.lock: nixpkgs ${old_rev:0:8} -> ${new_rev:0:8}"
fi

# --- (ii) the new rev is nixpkgs-unstable's, its narHash the real one
# Not tip equality: the channel may advance during a long build. The rev
# must be the tip or behind it, and ahead of the old one, as GitHub's
# compare says; a commit from a fork (served under NixOS/nixpkgs too)
# is on neither branch history, so it diverges.
if [ "$offline" = 0 ]; then
  compare() {
    curl -fsS --max-time 60 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/NixOS/nixpkgs/compare/$1...$2?per_page=1" |
      jq -r '.status'
  }
  status=$(compare "$new_rev" nixpkgs-unstable) || status="unreachable"
  case "$status" in
    identical | ahead) ok "$new_rev is on nixpkgs-unstable ($status)" ;;
    *) fail "$new_rev is not on nixpkgs-unstable (compare: $status)" ;;
  esac
  status=$(compare "$old_rev" "$new_rev") || status="unreachable"
  [ "$status" = ahead ] || fail "$new_rev does not descend from $old_rev (compare: $status)"
  prefetch=$(nix flake prefetch --json "github:NixOS/nixpkgs/$new_rev") ||
    die "nix flake prefetch github:NixOS/nixpkgs/$new_rev failed"
  if [ "$(jq -r '.hash' <<<"$prefetch")" != "$new_hash" ]; then
    fail "flake.lock: narHash is not the prefetched one"
  elif [ "$(jq -r '.locked.lastModified' <<<"$prefetch")" != "$new_mod" ]; then
    fail "flake.lock: lastModified is not the prefetched one"
  else
    ok "narHash matches nix flake prefetch"
  fi
else
  echo "nixpkgs-bump-guard: --offline: GitHub and prefetch checks SKIPPED (tests only)" >&2
fi

# --- (iv) denied paths: fixes may land after review, these never do
# Names NUL-separated from --raw (unquoted, any byte), each with its old
# and new mode: symlinks (120000) and submodules (160000) are denied
# wherever they are, and so are names with control characters.
gitd --raw -z "$base" "$head" >"$tmp/raw" || die "git diff --raw failed"
files=
special=
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r old_mode new_mode _ <<<"${meta#:}"
  case " $old_mode $new_mode " in
    *" 120000 "* | *" 160000 "*) special+="$path ($old_mode -> $new_mode)"$'\n' ;;
  esac
  if [[ "$path" =~ [[:cntrl:]] ]]; then
    special+="${path//[[:cntrl:]]/?} (control characters in the name)"$'\n'
  fi
  files+="$path"$'\n'
done <"$tmp/raw"
if [ -n "$special" ]; then
  fail "symlink, submodule or odd name changed:"$'\n'"$special"
fi
# Case-insensitive (grep -i): a case-folding checkout must not slip by.
denied_paths='(^|/)(vars|sops)/|-age\.key(/|$)|(^|/)flake\.nix$|/flake\.lock$'
denied_paths+='|^modules/nixos/infra-space/|^hyperhermes/|^modules/flake-parts/|^tools/'
denied_paths+='|^inventory\.json$|^default\.nix$|^shell\.nix$|(^|/)\.envrc$'
denied_paths+='|(^|/)\.gitattributes$|(^|/)\.gitmodules$|(^|/)\.git/'
denied_paths+='|^modules/admin-ssh-keys\.nix$'
# The secrets machinery outside infra-space/: every machine's copy of the
# age store (its repository URL, pull key, schedule) and GitHub's pinned
# host keys, which that copy and the agent's own known_hosts trust.
denied_paths+='|^modules/nixos/clan-secrets-mirror(-test)?\.nix$|^modules/github-host-keys\.nix$'
denied_paths+='|^\.github/|^\.gitlab-ci|^\.buildkite/|^\.garnix|^garnix\.yaml$|^\.hercules|buildbot'
# Fixes are Nix (step 4): any other file (scripts run as root, JSON the
# flake imports, keys, patches) is denied, flake.lock aside.
if hits=$(grep -vE '\.nix$|^flake\.lock$' <<<"$files" | grep .); then
  fail "only .nix files may change:"$'\n'"$hits"
fi
if hits=$(grep -iE "$denied_paths" <<<"$files"); then
  fail "denied paths changed:"$'\n'"$hits"
else
  ok "no denied path among: $(tr '\n' ' ' <<<"$files")"
fi

# --- (iv) denied options and fetches, in any changed line outside the
# root flake.lock and the three lines around it. Words, not option paths:
# nested attribute sets (`users = { users.eve ...`, `clan.core = { vars
# ...`) spell them apart; so do computed names (`${"user" + "s"}`), which
# are denied as such.
denied_opts='substituters|trusted-public-keys|trusted-users|allowed-users|trustedUsers'
denied_opts+='|\busers\b|\bgroups\b|mutableUsers|extraGroups|\bwheel\b|\bsudo\b|\bdoas\b'
denied_opts+='|\bsecurity\b|\bpam\b|polkit|wrappers|authorizedKeys|authorized_keys|knownHosts'
denied_opts+='|openssh|\bsshd?\b|cert-authority|certificateAuthority|TrustedUserCAKeys'
denied_opts+='|age\.key|\bsops\b|\bvars\b|\bclan\b|firewall|allowed(TCP|UDP)Port'
denied_opts+='|\bsystemd\b|serviceConfig|\bExec(Start|Stop|Reload|Condition)|\b(pre|post)Start\b|\bscript\b'
denied_opts+='|fetch[A-Za-z0-9]*|requireFile|outputHash|getFlake|builtins\s*\.\s*["$]|getAttr'
denied_opts+='|ecdsa-sha2|\bsk-|AAAA[A-Za-z0-9+/]{12,}|\$\{\s*"|"\s*\+\s*"'
denied_opts+='|\bcurl\b|\bwget\b|https?://|NIXPKGS_ALLOW'
denied_opts+='|allowBroken|allowInsecure|permittedInsecurePackages|allowUnsupportedSystem|--impure'
# Changed lines marked by indicators no file content can fake (a line
# `++ b/x` would read as a header in a plain diff's `+` marking).
gitd -U3 --output-indicator-new='>' --output-indicator-old='<' \
  --output-indicator-context='=' \
  "$base" "$head" -- . ':(top,literal,exclude)flake.lock' >"$tmp/diff" ||
  die "git diff failed"
# and the lines around them: an item added to a multi-line list
# (`allowedTCPPorts = [`, `keys = [`) names no option itself.
lines=$(grep -aE '^[<>=]' "$tmp/diff" || true)
if grep -q '^Binary files ' "$tmp/diff"; then
  fail "a change git shows as binary"
fi
if hits=$(grep -aiE "$denied_opts" <<<"$lines"); then
  fail "denied options or fetches in changed lines:"$'\n'"$hits"
else
  ok "no denied option or fetch in the changed lines"
fi

if [ "$failed" != 0 ]; then
  echo "nixpkgs-bump-guard: push nothing; report failed" >&2
  exit 1
fi
if [ "$offline" = 1 ]; then
  echo "nixpkgs-bump-guard: PASS-OFFLINE (not a push permit)"
  exit 3
fi
echo "nixpkgs-bump-guard: PASS"
