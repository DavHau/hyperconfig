# sec-job-guard: the security jobs' last check before a push
# (../security-jobs/*/SKILL.md), run at the root of the job's workspace.
# Exit 0 and a last line `sec-job-guard: PASS`: the push may go ahead;
# anything else: push nothing.
#
# Two layers: a positive path allowlist is the primary filter; evaluated
# protected settings (./protected-check.sh with ./protected.nix) are the
# second. Only takedowns.json, the package-fix overlay list and its
# patches (modules/nixos/security-fixes/), and movable flake.lock inputs
# may land; the fleet-wide wrapper security-fixes.nix is fixed, so no job
# sets a NixOS option through it. Every other path is refused.
#
# This runs as infra inside sec-job-push, on an immutable commit in a fresh
# clone. The job account has no push key and cannot select the guard's copy:
# push.sh calls deployed main's /run/current-system/sec-job-guard with
# --commits BASE HEAD. The legacy jj/@ form below remains for direct checks.
# What it refuses, between BASE and HEAD:
#   - every path outside that allowlist, plus symlinks, submodules and
#     non-text files;
#   - flake.lock: new or removed nodes, an input's `original` or wiring
#     changed, or a locked rev moved outside the inputs named in
#     $movable_inputs (and their own sub-inputs). nixpkgs is the bump's
#     job; clan-core, srvos and the rest need a session's review;
#   - added lines that open access: firewall openings (allowed*Ports,
#     openFirewall = true, trustedInterfaces), nix trust (substituters,
#     trusted-public-keys, trusted-users, allowed-users), ssh keys and key
#     material, sudo/polkit/PAM/security wrappers, new groups,
#     permittedInsecurePackages / allowInsecure / NIXPKGS_ALLOW*;
#     attribute names computed from strings (concatStrings, getAttr,
#     listToAttrs, nameValuePair, "a" + "b", ${"..."});
#   - never locking Dave out (policy rule 2), on added AND removed lines
#     alike (removing a firewall line is no exemption):
#       * lines naming sshd/openssh, the mesh (zerotier, yggdrasil,
#         wireguard, tailscale, tinc/retiolum, hyprspace), pocket-id/oidc,
#         id.davhau.com, infra-space, port 22, DNS (nameservers, resolved,
#         dnscrypt), DHCP and routes (useDHCP, defaultGateway, interfaces,
#         systemd.network), the firewall itself (enable, interfaces,
#         allowed*, trusted*, extraCommands, extraInputRules,
#         nftables.ruleset), boot (boot.initrd, kernelParams), users
#         (users.users, wheel, extraGroups, hashedPassword, password,
#         authorizedKeys), certificates (security.acme), the takedown
#         allowlist (takedown.eligible);
#       * a hunk whose context names one of those lists (an item added
#         to or removed from allowedTCPPorts, authorizedKeys, ...);
#       * an added `enable = ... false` or `mkForce false` outside
#         modules/nixos/security-takedown/takedowns.json: a takedown
#         goes through that file, whose module allows eligible units only;
#       * the paths of the mesh, the login path and disk unlock at boot
#         (modules/clan/{oidc,wireguard,zerotier,clan-unlock},
#         modules/nixos/{ssh.nix,tang-client,luks-unlock,
#         zfs-remote-unlock,clan-unlock,unlock-target.nix}) and the
#         takedown module with its allowlist
#         (modules/nixos/security-takedown/{default,eligible}.nix);
#   - takedowns: more than one new entry per push, or a new entry when
#     main@origin already gained one in the last 20 hours (at most one
#     takedown per night).
# A mitigation of a protected service is prepared but never pushed by a
# job: a session lands it. Whether a narrowing is something Dave would
# notice is the policy's bar (a question for Dave), not the guard's.
#
#   sec-job-guard [--offline]
#
# --offline: for ./guard-test.nix; never passes (PASS-OFFLINE, exit 3).

# writeShellApplication sets -e; failures here are handled one by one.
set +e

offline=0
exact=0
case "${1:-}" in
  --offline) offline=1; shift ;;
  "") ;;
  --commits)
    exact=1
    shift
    [ $# = 2 ] || { echo "usage: sec-job-guard --commits BASE HEAD" >&2; exit 2; }
    exact_base=$1
    exact_head=$2
    ;;
  *)
    echo "usage: sec-job-guard [--offline] | sec-job-guard --commits BASE HEAD" >&2
    exit 2
    ;;
esac
[ $# = 0 ] || [ "$exact" = 1 ] || { echo "usage: sec-job-guard [--offline]" >&2; exit 2; }

die() {
  echo "sec-job-guard: FAIL: $*" >&2
  echo "sec-job-guard: push nothing" >&2
  exit 1
}
failed=0
fail() {
  echo "sec-job-guard: FAIL: $*" >&2
  failed=1
}
ok() { echo "sec-job-guard: ok: $*"; }

gitd() {
  git -c core.quotePath=false -c core.ignoreCase=false -c diff.external= \
    -c core.attributesFile=/dev/null \
    diff --no-ext-diff --no-textconv --text --no-renames --no-color \
    --no-relative --ignore-submodules=none "$@"
}

ws=$(pwd -P)
if [ "$exact" = 1 ]; then
  base=$exact_base
  head=$exact_head
  for r in "$base" "$head"; do
    case "$r" in *[!0-9a-f]* | "") die "not a full commit id: $r" ;; esac
    [ ${#r} = 40 ] || die "not a full commit id: $r"
    git cat-file -e "$r^{commit}" 2>/dev/null || die "not a commit in this repository: $r"
  done
  git merge-base --is-ancestor "$base" "$head" || die "$head does not descend from $base"
  [ "$base" != "$head" ] || die "HEAD is origin/main: nothing to push"
  gitd --quiet "$base" "$head" && die "no tree change between $base and $head"
else
  name=$(basename "$ws")
  case "$name" in
    hyperconfig-sec-*) ;;
    *) die "not in a security job workspace (hyperconfig-sec-*): $ws" ;;
  esac
  root=$(jj root 2>/dev/null) || die "no jj workspace at $ws"
  [ "$(cd "$root" && pwd -P)" = "$ws" ] || die "run it at the workspace root ($root), not $ws"
  base=$(jj log --no-graph -r 'main@origin' -T 'commit_id') || die "no main@origin"
  head=$(jj log --no-graph -r '@' -T 'commit_id')
  [ -n "$(jj log --no-graph -r 'main@origin & ::@' -T 'commit_id')" ] ||
    die "@ does not descend from main@origin: fetch and rebase first"
  [ -z "$(jj log --no-graph -r '(main@origin..@) & conflicts()' -T 'commit_id')" ] ||
    die "conflicted commits between main@origin and @"
  [ "$base" != "$head" ] || die "@ is main@origin: nothing to push"
  [ -z "$(jj log --no-graph -r '(main@origin..@) & (empty() | description(exact:""))' -T 'commit_id')" ] ||
    die "an empty or undescribed commit between main@origin and @"
fi
ok "HEAD ($head) on origin/main ($base)"

# --- paths: a positive allowlist, not a deny list. Only takedowns
# (data), the package-fix overlay list and its patches, and movable lock
# inputs can land unattended. Everything else is a session patch.
allowed_path() {
  case "$1" in
    modules/nixos/security-takedown/takedowns.json | modules/nixos/security-fixes/overlays.nix | flake.lock) return 0 ;;
  esac
  echo "$1" | grep -Eq '^modules/nixos/security-fixes/[A-Za-z0-9._-]+\.patch$'
}
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  mode_new=$(echo "$meta" | cut -d' ' -f2)
  case "$path" in
    *[[:cntrl:]]*) fail "control character in a path name" ; continue ;;
  esac
  allowed_path "$path" || fail "path outside the security-job allowlist: $path"
  case "$mode_new" in
    120000) fail "symlink: $path" ;;
    160000) fail "submodule: $path" ;;
  esac
  case "$path" in
    *.nix | *.md | *.sh | *.py | *.json | *.toml | *.yaml | *.yml | *.txt | *.patch | *.diff) ;;
    flake.lock) ;;
    *) fail "not a text file type the jobs change: $path" ;;
  esac
done < <(gitd --raw -z "$base" "$head")
# --- flake.lock: same nodes, same originals, and only the named inputs
# move (with their own sub-inputs). nixpkgs moves with the nightly bump
# (its build of every machine); clan-core, srvos and everything else
# need a session's review of the source diff.
movable_inputs='afk llm-agents nixpkgs-php nixpkgs-llama-cpp'
never_movable='nixpkgs clan-core srvos teamclaude ncps'
if gitd --quiet "$base" "$head" -- flake.lock; then
  :
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  git show "$base:flake.lock" >"$tmp/old.json" || die "no flake.lock on main@origin"
  git show "$head:flake.lock" >"$tmp/new.json" || die "no flake.lock in @"
  if jq -e -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" '
    ($a[0].nodes | keys) == ($b[0].nodes | keys)
    and ([$a[0].nodes[] | .original, .inputs] == [$b[0].nodes[] | .original, .inputs])
    and $a[0].root == $b[0].root' >/dev/null; then
    all_moved=$(jq -r -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" '
      $a[0].nodes as $n | [$n | keys[] | select($n[.].locked != $b[0].nodes[.].locked)] | .[]')
    # nodes whose lock moved, minus those reachable only from movable
    # inputs; anything reachable from a never-movable one stays refused
    moved=$(jq -r -n --slurpfile a "$tmp/old.json" --slurpfile b "$tmp/new.json" \
      --arg allow "$movable_inputs" --arg never "$never_movable" '
      $a[0].nodes as $n
      | def reach: [recurse($n[.].inputs // {} | .[] | select(type == "string"))] | unique;
      ($n[$a[0].root].inputs // {}) as $root
      | ([($allow | split(" "))[] | $root[.] // empty | select(type == "string") | reach] | add // []) as $ok
      | ([($never | split(" "))[] | $root[.] // empty | select(type == "string") | reach] | add // []) as $bad
      | [$n | keys[] | select($n[.].locked != $b[0].nodes[.].locked)]
      | map(select(. as $k | ($ok | index([$k])) == null or ($bad | index([$k])) != null))
      | .[]')
    if [ -n "$moved" ]; then
      fail "flake.lock: inputs outside the movable list ($movable_inputs) moved: $(echo "$moved" | tr '\n' ' ')"
    else
      ok "flake.lock: only movable inputs moved"
      # Existence on GitHub is not ancestry: fork objects are reachable
      # through the parent too. Check the tracked ref on the real remote.
      for node in $all_moved; do
        sec-job-input-ancestry "$node" "$tmp/old.json" "$tmp/new.json" || failed=1
      done
    fi
  else
    fail "flake.lock: nodes added/removed, or an input's original or wiring changed (only existing inputs may move)"
  fi
fi

# --- added lines (with the three lines of context around each, which
# name the option an added list item belongs to)
added=$(gitd -U3 "$base" "$head" -- . ':(exclude)flake.lock' | grep -E '^\+[^+]' || true)
denied_added='allowed(TCP|UDP)Port|openFirewall[[:space:]]*=[[:space:]]*true|trustedInterfaces|substituters|trusted-public-keys|trusted-users|allowed-users|trustedUsers|authorizedKeys|authorized_keys|ssh-(ed25519|rsa|dss)|ecdsa-sha2|sk-ssh|AAAA[A-Za-z0-9+/]{20}|-----BEGIN|\bsudo\b|wheelNeedsPassword|extraRules|\bwheel\b|polkit|security\.pam|\bpam\b|security\.wrappers|setuid|users\.users\.[^.]+\.(isNormalUser|isSystemUser|extraGroups|hashedPassword|password)|users\.groups|permittedInsecurePackages|allowInsecure|allowBroken|NIXPKGS_ALLOW|\$\{"|"[[:space:]]*\+[[:space:]]*"|concatStrings|getAttr|attrByPath|listToAttrs|nameValuePair'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if echo "$line" | grep -Eiq "$denied_added"; then
    fail "added line opens access or trust: ${line:0:200}"
  fi
done <<<"$added"
# An item added to or removed from an existing list of one of those
# options names no option itself: any hunk that changes a line and whose
# text (context included) names such a list fails, either direction.
lists='allowed(TCP|UDP)Port|trustedInterfaces|authorizedKeys|extraGroups|substituters|trusted-public-keys|trusted-users|allowedUsers|openFirewall|nameservers|interfaces|kernelParams|initrd|extraInputRules|extraCommands|ruleset|users[.]users|hashedPassword'
if gitd -U3 "$base" "$head" -- . ':(exclude)flake.lock' |
  awk -v re="$lists" '
    function flush() { if (chg && tolower(h) ~ tolower(re)) bad = 1; h = ""; chg = 0 }
    /^@@/ { flush(); next }
    /^\+\+\+ |^--- / { next }
    /^[+-]/ { chg = 1 }
    { h = h "\n" $0 }
    END { flush(); exit bad ? 0 : 1 }'; then
  fail "a hunk changes lines next to a firewall, DNS, boot, user, key, group or nix trust option (a list item added or removed?)"
fi

# --- never lock Dave out: changed lines (either side) naming sshd, the
# mesh, the login path, port 22, or what they depend on (firewall, DNS,
# DHCP/routes, boot, users, certificates, the takedown allowlist)
# (port 22 only as a list item or a port setting, not inside versions)
lockout='openssh|\bsshd?\b|zerotier|yggdrasil|wireguard|\bwg[0-9-]|tailscale|retiolum|\btinc\b|hyprspace|pocket-?id|\boidc\b|id\.davhau\.com|infra-space|extraCommands|extraStopCommands|extraInputRules|extraForwardRules|nftables\.(ruleset|tables|enable)|firewall\.(enable|interfaces|allowed|trusted|extra|filterForward|checkReversePath)|networking\.(interfaces|nameservers|useDHCP|useNetworkd|defaultGateway|hosts|resolvconf)|nameservers|useDHCP|defaultGateway|systemd\.network|services\.resolved|dnscrypt|boot\.initrd|initrd\.|kernelParams|users\.users|\bwheel\b|extraGroups|hashedPassword|initialPassword|\bpassword(File)?\b|authorizedKeys|authorized_keys|security\.acme|takedown\.eligible'
port22='^[+-][[:space:]]*"?22"?[[:space:]]*;?$|ports?[^=]*=.*[^.0-9]22([^.0-9]|$)|port[[:space:]]*=[[:space:]]*"?22\b'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if echo "$line" | grep -Eiq "$lockout" || echo "$line" | grep -Eiq "$port22"; then
    fail "changes sshd, the mesh, pocket-id, port 22 or what they depend on (firewall, DNS, DHCP, boot, users; never lock Dave out; a session lands it): ${line:0:200}"
  fi
done < <(gitd -U0 "$base" "$head" -- . ':(exclude)flake.lock' | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' || true)

# --- turning things off: only through takedowns.json (its module allows
# only takedown-eligible units). Elsewhere an added `enable = ... false`
# or `mkForce false` is a takedown that skips that allowlist.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if echo "$line" | grep -Eiq 'enable[[:space:]]*=.*false|mkForce[[:space:]]+false'; then
    fail "turns something off outside takedowns.json (a takedown goes through modules/nixos/security-takedown/takedowns.json): ${line:0:200}"
  fi
done < <(gitd -U0 "$base" "$head" -- . ':(exclude)flake.lock' ':(exclude)modules/nixos/security-takedown/takedowns.json' | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)

# --- at most one takedown per night, counted on the data (machine, unit
# pairs added), not on patch lines: one new entry per push, none when
# main@origin gained one in the last 20 hours
td=modules/nixos/security-takedown/takedowns.json
td_tmp=$(mktemp -d)
td_at() { # REV FILE: the takedowns at REV ({} where the file is absent)
  if git cat-file -e "$1:$td" 2>/dev/null; then git show "$1:$td" >"$2"; else echo '{}' >"$2"; fi
}
td_added() { # OLD NEW: how many (machine, unit) pairs NEW adds
  jq -n --slurpfile a "$1" --slurpfile b "$2" '
    def valid: type == "object" and ([.[] | type == "object"] | all);
    def entries: [to_entries[] | .key as $m | (.value | keys[]) | [$m, .]];
    if ($a[0] | valid) and ($b[0] | valid)
    then (($b[0] | entries) - ($a[0] | entries)) | length
    else error("takedowns.json must map machine -> unit -> entry") end'
}
td_at "$base" "$td_tmp/old.json"
td_at "$head" "$td_tmp/new.json"
new_td=$(td_added "$td_tmp/old.json" "$td_tmp/new.json") || die "takedowns.json is not valid takedown data"
if [ "$new_td" -gt 1 ]; then
  fail "more than one new takedown in one push ($new_td): at most one per night"
elif [ "$new_td" = 1 ]; then
  recent=0
  for c in $(git log --since="20 hours ago" --format=%H "$base" -- "$td"); do
    if git rev-parse -q --verify "$c^" >/dev/null; then td_at "$c^" "$td_tmp/old.json"; else echo '{}' >"$td_tmp/old.json"; fi
    td_at "$c" "$td_tmp/new.json"
    n=$(td_added "$td_tmp/old.json" "$td_tmp/new.json") || n=1
    recent=$((recent + n))
  done
  if [ "$recent" -gt 0 ]; then
    fail "main@origin already gained a takedown in the last 20 hours: at most one per night"
  fi
fi
rm -rf "$td_tmp"

if [ "$failed" != 0 ]; then
  echo "sec-job-guard: push nothing" >&2
  exit 1
fi

# --- the evaluated configuration (the second layer, after the path
# allowlist and line checks): ./protected-check.sh evaluates
# ./protected.nix on every machine of main@origin and of @ and refuses
# any difference in the network, sshd, resolved, users, PAM, boot, file
# systems, nix trust, the protected units, protected /etc entries,
# sysctls, activation scripts, tmpfiles, the set of units and the
# takedown allowlist. A takedown of an eligible unit is the one change
# it lets through. --offline (the sandboxed test) has no flake to
# evaluate and never passes anyway.
if [ "$offline" = 1 ]; then
  echo "sec-job-guard: evaluation check skipped (--offline)"
else
  sec-job-protected-check "$base" "$head" "$ws" || die "the evaluated protected settings differ (sec-job-protected-check above)"
  ok "evaluated protected settings unchanged on every machine"
fi
if [ "$offline" = 1 ]; then
  echo "sec-job-guard: PASS-OFFLINE (not a permit)"
  exit 3
fi
# main on GitHub still where the run's fetch saw it
remote=$(git ls-remote origin refs/heads/main | cut -f1) || die "git ls-remote origin failed"
[ "$remote" = "$base" ] || die "main on origin is $remote, not main@origin ($base): fetch, rebase, re-run the gates"
echo "sec-job-guard: PASS"
