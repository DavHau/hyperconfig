# sec-job-guard: the security jobs' last check before a push
# (../security-jobs/*/SKILL.md), run at the root of the job's workspace.
# Exit 0 and a last line `sec-job-guard: PASS`: the push may go ahead;
# anything else: push nothing.
#
# Two layers: the primary one evaluates the configuration
# (./protected-check.sh with ./protected.nix: any difference in what
# could lock Dave out, on any machine, is refused, however the edit is
# written); the path and line checks below are a cheap pre-filter in
# front of it.
#
# Advisory, not a boundary (the agent holds the push key): it catches
# drift and injected edits a run that reads advisories, logs and live
# machine state may have picked up. What it refuses, from the exact
# commits between main@origin and @:
#   - paths that decide who gets in or what gets trusted: vars/, sops/,
#     age keys, the admin ssh keys, GitHub's host keys, the secrets
#     mirror, the agent's own module (modules/nixos/infra-space/),
#     hyperhermes/ (the agent's runtime), flake.nix, CI, .gitattributes,
#     .envrc, symlinks, submodules, non-text files; skills/ and every
#     skill or agent-instruction file (SKILL.md, *-skill/, AGENTS.md,
#     SOUL.md, MEMORY.md, ...), which later sessions follow;
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
#         modules/nixos/security-takedown/takedowns.nix: a takedown
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
case "${1:-}" in
  --offline) offline=1 ;;
  "") ;;
  *)
    echo "usage: sec-job-guard [--offline]" >&2
    exit 2
    ;;
esac

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
ok "@ ($head) on main@origin ($base)"

# --- paths (names NUL-separated from --raw: quoting can't hide them)
# skills/ (shipped to the agents), any skill or agent-instruction file
# elsewhere (SKILL.md, a *-skill/ or skills/ directory, AGENTS.md,
# CONVENTIONS.md, SOUL.md, MEMORY.md, USER.md): what later sessions read
# as instructions, so a run steered by what it read cannot plant it.
denied_paths='^skills/|(^|/)skills?/|-skills?/|(^|/)(SKILL|AGENTS|CONVENTIONS|SOUL|MEMORY|USER)\.md$|^modules/nixos/security-takedown/(default|eligible)\.nix$|^modules/clan/(oidc|wireguard|zerotier|clan-unlock)/|^modules/nixos/ssh\.nix$|^modules/nixos/(tang-client|luks-unlock|zfs-remote-unlock|clan-unlock)(/|\.nix$)|^modules/nixos/unlock-target\.nix$|(^|/)(vars|sops)/|-age\.key(/|$)|(^|/)flake\.nix$|^hyperhermes/|^modules/nixos/infra-space/|^modules/admin-ssh-keys\.nix$|^modules/github-host-keys\.nix$|^modules/nixos/clan-secrets-mirror|^\.github/|^\.gitlab|(^|/)\.gitattributes$|(^|/)\.envrc$|(^|/)\.gitmodules$|(^|/)flake\.lock$'
while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  mode_new=$(echo "$meta" | cut -d' ' -f2)
  case "$path" in
    *[[:cntrl:]]*) fail "control character in a path name" ; continue ;;
  esac
  if [ "$path" != flake.lock ] && echo "$path" | grep -Eiq "$denied_paths"; then
    fail "denied path: $path"
  fi
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
movable_inputs='afk llm-agents teamclaude ncps nixpkgs-php nixpkgs-llama-cpp'
never_movable='nixpkgs clan-core srvos'
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

# --- turning things off: only through takedowns.nix (its module allows
# only takedown-eligible units). Elsewhere an added `enable = ... false`
# or `mkForce false` is a takedown that skips that allowlist.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if echo "$line" | grep -Eiq 'enable[[:space:]]*=.*false|mkForce[[:space:]]+false'; then
    fail "turns something off outside takedowns.nix (a takedown goes through modules/nixos/security-takedown/takedowns.nix): ${line:0:200}"
  fi
done < <(gitd -U0 "$base" "$head" -- . ':(exclude)flake.lock' ':(exclude)modules/nixos/security-takedown/takedowns.nix' | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)

# --- at most one takedown per night: one new entry per push, none when
# main@origin gained one in the last 20 hours
td=modules/nixos/security-takedown/takedowns.nix
new_td=$(gitd -U0 "$base" "$head" -- "$td" | grep -cE '^\+[^+#]*\.service"[[:space:]]*=')
if [ "$new_td" -gt 1 ]; then
  fail "more than one new takedown in one push ($new_td): at most one per night"
elif [ "$new_td" = 1 ]; then
  recent=$(git log --since="20 hours ago" -p --format= "$base" -- "$td" | grep -cE '^\+[^+#]*\.service"[[:space:]]*=')
  if [ "$recent" -gt 0 ]; then
    fail "main@origin already gained a takedown in the last 20 hours: at most one per night"
  fi
fi

if [ "$failed" != 0 ]; then
  echo "sec-job-guard: push nothing" >&2
  exit 1
fi

# --- the evaluated configuration (the primary lock-out check; the line
# checks above are a cheap pre-filter): ./protected-check.sh evaluates
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
