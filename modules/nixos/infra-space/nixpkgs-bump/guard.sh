# nixpkgs-bump-guard: the nightly bump's last check before it pushes
# (../nixpkgs-bump/SKILL.md step 6), run in the bump workspace. Exit 0
# and a last line `nixpkgs-bump-guard: PASS`: the push may go ahead;
# anything else: push nothing, the night failed.
#
# Advisory, not a boundary: the agent holds the deploy key and could push
# without it. It mechanically catches drift and injected edits a long run
# may have picked up: a lock that moved more than nixpkgs (and searxng),
# to something that is not nixpkgs-unstable (searxng's master), a SearXNG
# pin the search canary did not pass, a bump that raced another one, and changes
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
#
# The root `searxng` input (web_search's SearXNG at upstream master, a
# source with flake = false) may move too, like nixpkgs: plain
# github:searxng/searxng, forward, on master, the prefetched narHash; a
# master tip we first saw at least @minAgeHours@ h ago, or (online) an
# ancestor of one (our own record @logDir@/searxng-tips.jsonl, never
# upstream's commit dates); and only with an approved code review of
# exactly old..new and of exactly the picked diff (its hash and its
# parts' hash in the pick file) and a canary PASS for exactly this lock (nixpkgs-bump-searxng's
# files @logDir@/<workspace dir name>.searxng-{pick,diff,review,canary},
# steps 2a-2c of the skill).
#
# That review is a subagent of the bump agent itself, and these files are
# written by the same uid, the age gate's record
# @logDir@/searxng-tips.jsonl included: the checks catch a skipped step or
# a mix-up (a review of another pair or diff, a stale canary, a tip too
# young), not a compromised agent, which can write any of them (a
# backdated first sighting in searxng-tips.jsonl too).

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

# --- (i) flake.lock: only the root nixpkgs (and searxng) node's `locked` moved
sx=$(jq -r '.nodes.root.inputs.searxng | strings' "$tmp/old.json")
sx_new=$(jq -r '.nodes.root.inputs.searxng | strings' "$tmp/new.json")
[ "$sx" = "$sx_new" ] || die "flake.lock: root searxng node changed ('$sx' -> '$sx_new')"
node=$(jq -r '.nodes.root.inputs.nixpkgs | strings' "$tmp/old.json")
node_new=$(jq -r '.nodes.root.inputs.nixpkgs | strings' "$tmp/new.json")
[ -n "$node" ] && [ "$node" = "$node_new" ] ||
  die "flake.lock: root nixpkgs node changed ('$node' -> '$node_new')"
jq -e -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" --arg n "$node" --arg s "$sx" \
  'def strip: del(.nodes[$n].locked) | if $s == "" then . else del(.nodes[$s].locked) end;
    ($a[0] | strip) == ($b[0] | strip)' >/dev/null ||
  fail "flake.lock: more than nixpkgs' and searxng's locked changed (other nodes, new nodes, or original)"
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
if [ "$new_rev" = "$old_rev" ] && [ "$(jq -r --arg n "$sx" '.nodes[$n].locked.rev? // ""' "$tmp/old.json")" = "$(jq -r --arg n "$sx" '.nodes[$n].locked.rev? // ""' "$tmp/new.json")" ]; then
  fail "flake.lock: neither nixpkgs nor searxng moved"
elif [ "$new_rev" = "$old_rev" ]; then
  ok "flake.lock: nixpkgs stays at ${old_rev:0:8} (searxng moved)"
elif [ "$new_mod" -lt "$(locked old lastModified)" ]; then
  fail "flake.lock: lastModified went backwards"
else
  ok "flake.lock: nixpkgs ${old_rev:0:8} -> ${new_rev:0:8}"
fi

# --- (ii) the new rev is nixpkgs-unstable's, its narHash the real one
# Not tip equality: the channel may advance during a long build. The rev
# must be the tip or behind it, and ahead of the old one, as GitHub's
# compare says; a commit from a fork (served under NixOS/nixpkgs too)
# is on neither branch history, so it diverges. (A night where only
# searxng moved has nothing to check here.)
if [ "$offline" = 0 ] && [ "$new_rev" = "$old_rev" ]; then
  ok "nixpkgs did not move: its GitHub and prefetch checks do not apply"
elif [ "$offline" = 0 ]; then
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

# --- (v) searxng: the same checks against searxng/searxng master, plus
# the canary's PASS for exactly this lock
sx_moved=0
if [ -n "$sx" ]; then
  sxl() { jq -r --arg n "$sx" ".nodes[\$n].$2" "$tmp/$1.json"; }
  jq -e --arg n "$sx" '.nodes[$n].original == {owner: "searxng", repo: "searxng", type: "github"}
      and .nodes[$n].flake == false' "$tmp/new.json" >/dev/null ||
    fail "flake.lock: searxng's original is not github:searxng/searxng (flake = false)"
  jq -e --arg n "$sx" '.nodes[$n].locked as $l
      | ($l | keys) == ["lastModified", "narHash", "owner", "repo", "rev", "type"]
      and $l.owner == "searxng" and $l.repo == "searxng" and $l.type == "github"
      and ($l.rev | test("^[0-9a-f]{40}$"))
      and ($l.narHash | test("^sha256-[A-Za-z0-9+/]{43}=$"))
      and ($l.lastModified | type) == "number"' \
    "$tmp/new.json" >/dev/null ||
    fail "flake.lock: searxng's locked is not a plain github:searxng/searxng rev"
  sx_old=$(sxl old locked.rev)
  sx_rev=$(sxl new locked.rev)
  if [ "$sx_rev" = "$sx_old" ]; then
    ok "flake.lock: searxng stays at ${sx_old:0:8}"
  elif [ "$(sxl new locked.lastModified)" -lt "$(sxl old locked.lastModified)" ]; then
    fail "flake.lock: searxng's lastModified went backwards"
  else
    sx_moved=1
    ok "flake.lock: searxng ${sx_old:0:8} -> ${sx_rev:0:8}"
  fi
fi
if [ "$sx_moved" = 1 ]; then
  # Upstream code waits @minAgeHours@ h before it runs here, by our own
  # clock: a master tip first seen that long ago (the record of
  # nixpkgs-bump-searxng pick), or online an ancestor of the newest such
  # tip. Commit dates prove nothing: the committer sets them.
  sx_ancestor() { # a b: a is b or behind it on GitHub's compare
    local st
    st=$(curl -fsS --max-time 60 -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/searxng/searxng/compare/$1...$2?per_page=1" | jq -r '.status') || return 1
    [ "$st" = identical ] || [ "$st" = ahead ]
  }
  tips=@logDir@/searxng-tips.jsonl
  cut=$(($(date +%s) - @minAgeHours@ * 3600))
  aged=$(jq -rs --argjson cut "$cut" \
    'group_by(.tip) | map(min_by(.epoch)) | map(select(.epoch <= $cut))
      | sort_by(.epoch) | map(.tip) | .[]' "$tips" 2>/dev/null) || aged=
  newest_aged=$(tail -n 1 <<<"$aged")
  if grep -qxF -- "$sx_rev" <<<"$aged"; then
    ok "searxng ${sx_rev:0:8} is a master tip first seen at least @minAgeHours@ h ago ($tips)"
  elif [ "$offline" = 0 ] && [ -n "$newest_aged" ] && sx_ancestor "$sx_rev" "$newest_aged"; then
    ok "searxng ${sx_rev:0:8} is an ancestor of ${newest_aged:0:8}, a master tip first seen at least @minAgeHours@ h ago"
  else
    fail "searxng ${sx_rev:0:8} is not a master tip first seen at least @minAgeHours@ h ago, nor an ancestor of one ($tips)"
  fi
  pick_file=@logDir@/$name.searxng-pick
  diff_file=@logDir@/$name.searxng-diff
  review_file=@logDir@/$name.searxng-review
  p_old='' p_new='' p_hash='' p_n='' p_parts=''
  read -r p_old p_new p_hash p_n p_parts _ <"$pick_file" 2>/dev/null || true
  # the parts the review read (nixpkgs-bump-searxng's parts_hash): the
  # count, then `<i> <bytes> <sha256>` of part-01..NN in order (the exact
  # split); no gap, no stray part
  sx_parts_hash() {
    local n=0 all h i p
    while [ -f "$(printf '%s.part-%02d' "$diff_file" $((n + 1)))" ]; do n=$((n + 1)); done
    all=$(find "$(dirname "$diff_file")" -maxdepth 1 -name "$(basename "$diff_file").part-*" | wc -l)
    [ "$n" -gt 0 ] && [ "$all" = "$n" ] || return 1
    h=$({
      echo "$n"
      for i in $(seq 1 "$n"); do
        p=$(printf '%s.part-%02d' "$diff_file" "$i")
        printf '%s %s %s\n' "$i" "$(wc -c <"$p")" "$(sha256sum <"$p" | cut -c1-64)"
      done
    } | sha256sum | cut -c1-64) || return 1
    echo "$n $h"
  }
  if [ "$p_old $p_new" != "$sx_old $sx_rev" ] || ! [[ $p_hash =~ ^[0-9a-f]{64}$ ]] ||
    ! [[ $p_n =~ ^[0-9]+$ ]] || ! [[ $p_parts =~ ^[0-9a-f]{64}$ ]]; then
    fail "searxng moved without a pick of ${sx_old:0:8}..${sx_rev:0:8} (nixpkgs-bump-searxng pick; $pick_file)"
  elif [ "$(sha256sum <"$diff_file" 2>/dev/null | cut -c1-64)" != "$p_hash" ]; then
    fail "searxng: the reviewed diff changed since the pick ($diff_file)"
  elif [ "$(sx_parts_hash || true)" != "$p_n $p_parts" ]; then
    fail "searxng: the reviewed diff's parts changed since the pick ($diff_file.part-NN)"
  elif [ "$(cat "$review_file" 2>/dev/null)" != "approve searxng=$sx_old..$sx_rev diff=$p_hash" ]; then
    fail "searxng moved without an approved code review of ${sx_old:0:8}..${sx_rev:0:8} and the picked diff (nixpkgs-bump-searxng review; $review_file)"
  else
    ok "searxng ${sx_old:0:8}..${sx_rev:0:8}: code review approved, of the picked diff"
  fi
  verdict_file=@logDir@/$name.searxng-canary
  want="PASS searxng=$sx_rev nixpkgs=$new_rev"
  if [ "$(cat "$verdict_file" 2>/dev/null)" = "$want" ]; then
    ok "searxng canary passed for this lock"
  else
    fail "searxng moved without a passed canary for this lock (nixpkgs-bump-searxng canary; $verdict_file)"
  fi
  if [ "$offline" = 0 ]; then
    sx_compare() {
      curl -fsS --max-time 60 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/searxng/searxng/compare/$1...$2?per_page=1" |
        jq -r '.status'
    }
    status=$(sx_compare "$sx_rev" master) || status="unreachable"
    case "$status" in
      identical | ahead) ok "$sx_rev is on searxng's master ($status)" ;;
      *) fail "$sx_rev is not on searxng's master (compare: $status)" ;;
    esac
    status=$(sx_compare "$sx_old" "$sx_rev") || status="unreachable"
    [ "$status" = ahead ] || fail "searxng $sx_rev does not descend from $sx_old (compare: $status)"
    prefetch=$(nix flake prefetch --json "github:searxng/searxng/$sx_rev") ||
      die "nix flake prefetch github:searxng/searxng/$sx_rev failed"
    if [ "$(jq -r '.hash' <<<"$prefetch")" != "$(sxl new locked.narHash)" ]; then
      fail "flake.lock: searxng's narHash is not the prefetched one"
    elif [ "$(jq -r '.locked.lastModified' <<<"$prefetch")" != "$(sxl new locked.lastModified)" ]; then
      fail "flake.lock: searxng's lastModified is not the prefetched one"
    else
      ok "searxng's narHash matches nix flake prefetch"
    fi
  fi
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
denied_paths+='|^modules/nixos/infra-space/|^modules/flake-parts/|^tools/'
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
# hyperhermes/ (the agents' own flake) is denied but for a short
# allowlist: its trust core (accounts, hardening, firewall, locked config,
# SSO, auth, mail, wallet keys, container slots and their storage, the
# clan glue, checks, library) is most of it, and a new file there must
# not slip through a list of what is denied. Allowed: phoenixd.nix (a
# version guard that throws on a nixpkgs version), the packages but
# tcp-owner-bridge (the owner-gated bridge), the browser modules but the
# SearXNG package (the pin's build), searxng.nix (its secret key and
# limits) and camofox.nix (its access key and iptables owner rules).
# The allowlist is matched case-sensitively, the exceptions not.
hh_allowed='^hyperhermes/(modules/wallet/phoenixd\.nix|pkgs/[^/].*|modules/browser/[^/].*)$'
hh_except='^hyperhermes/(pkgs/tcp-owner-bridge/|modules/browser/(searxng-package|searxng|camofox)\.nix$)'
hh_denied=
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if [[ "$f" =~ $hh_allowed ]] && ! grep -qiE "$hh_except" <<<"$f"; then
    continue
  fi
  hh_denied+="$f (hyperhermes/ outside its allowlist)"$'\n'
done < <(grep -iE '^hyperhermes/' <<<"$files" || true)
if hits=$({ grep -iE "$denied_paths" <<<"$files" || true; printf '%s' "$hh_denied"; } | grep .); then
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
denied_opts+='|secret|credential|token|LoadCredential|iptables'
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
