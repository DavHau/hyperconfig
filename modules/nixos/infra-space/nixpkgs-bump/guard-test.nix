# ./guard.sh against a scratch repository, without network: `curl` and
# `nix` are stubs that answer GitHub's compare and `nix flake prefetch`
# from files under $STUB. Each case starts from main@origin, makes one
# change, and expects the guard to pass or to fail with a given reason.
{ pkgs }:
let
  # GitHub's compare API: $STUB/compare/<owner>/<repo>/<base>...<head>
  # holds the status; none means unreachable (curl -f fails).
  curl = pkgs.writeShellApplication {
    name = "curl";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      url=''${*: -1}
      spec=''${url#https://api.github.com/repos/}
      spec=''${spec%%\?*}
      spec=''${spec/\/compare\//\/}
      [ -r "$STUB/compare/$spec" ] || { echo "curl stub: unreachable $spec" >&2; exit 7; }
      printf '{"status": "%s"}\n' "$(cat "$STUB/compare/$spec")"
    '';
  };
  # `nix flake prefetch --json github:<owner>/<repo>/<rev>`: $STUB/prefetch/<rev>
  nix = pkgs.writeShellApplication {
    name = "nix";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      [ "$#" = 4 ] && [ "$1 $2 $3" = "flake prefetch --json" ] || { echo "nix stub: $*" >&2; exit 2; }
      rev=''${4##*/}
      [ -r "$STUB/prefetch/$rev" ] || { echo "nix stub: cannot fetch $4" >&2; exit 1; }
      cat "$STUB/prefetch/$rev"
    '';
  };
  guard = import ./guard.nix { inherit pkgs nix curl; };
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
    sxold=5555555555555555555555555555555555555555
    sxnew=6666666666666666666666666666666666666666
    hash="sha256-$(printf 'A%.0s' {1..43})="
    lock() { # nixpkgs rev, searxng rev
      jq -n --arg rev "$1" --arg sxrev "$2" --arg hash "$hash" '{
        nodes: {
          root: {inputs: {nixpkgs: "nixpkgs_4", disko: "disko", searxng: "searxng"}},
          searxng: {flake: false,
            locked: {lastModified: 100, narHash: $hash,
              owner: "searxng", repo: "searxng", rev: $sxrev, type: "github"},
            original: {owner: "searxng", repo: "searxng", type: "github"}},
          nixpkgs_4: {
            locked: {lastModified: 100, narHash: $hash,
              owner: "NixOS", repo: "nixpkgs", rev: $rev, type: "github"},
            original: {owner: "NixOS", ref: "nixpkgs-unstable", repo: "nixpkgs", type: "github"}},
          disko: {
            locked: {lastModified: 1, narHash: "sha256-\("B" * 43)=",
              owner: "nix-community", repo: "disko", rev: "\("3" * 40)", type: "github"},
            original: {owner: "nix-community", repo: "disko", type: "github"}}},
        root: "root", version: 7}'
    }
    stub_good() {
      rm -rf "$STUB"
      mkdir -p "$STUB/compare/NixOS/nixpkgs" "$STUB/compare/searxng/searxng" "$STUB/prefetch"
      echo identical >"$STUB/compare/NixOS/nixpkgs/$new...nixpkgs-unstable"
      echo ahead >"$STUB/compare/NixOS/nixpkgs/$old...$new"
      echo identical >"$STUB/compare/searxng/searxng/$sxnew...master"
      echo ahead >"$STUB/compare/searxng/searxng/$sxold...$sxnew"
      for r in $new $sxnew; do
        jq -n --arg hash "$hash" '{hash: $hash, locked: {lastModified: 100}}' >"$STUB/prefetch/$r"
      done
    }

    git init -q --bare origin.git
    git init -q seed
    (
      cd seed
      lock $old $sxold >flake.lock
      mkdir -p vars/shared
      echo secret >vars/shared/value
      echo '{ }' >flake.nix
      git add -A
      git commit -qm init
      git push -q ../origin.git main
    )
    ws=$PWD/ws
    jj git clone --colocate origin.git "$ws" >/dev/null 2>&1
    cd "$ws"

    run() { # expect(pass|fail) description why(the FAIL line's pattern) edit...
      local expect=$1 what=$2 why=$3 rc=0 got
      shift 3
      stub_good
      jj new main@origin >/dev/null 2>&1
      "$@"
      jj describe -m "$what" >/dev/null 2>&1
      jj new >/dev/null 2>&1
      nixpkgs-bump-guard >"$TMPDIR/out" 2>&1 || rc=$?
      if [ "$rc" = 0 ] && [ "$(tail -n 1 "$TMPDIR/out")" = "nixpkgs-bump-guard: PASS" ]; then
        got=pass
      elif [ "$rc" = 1 ] && ! grep -q PASS "$TMPDIR/out"; then
        got=fail
      else
        got="exit $rc"
      fi
      if [ "$got" != "$expect" ] || { [ "$got" = fail ] && ! grep -q "FAIL: .*$why" "$TMPDIR/out"; }; then
        cat "$TMPDIR/out"
        echo "FAILED: $what: expected $expect ($why), got $got"
        exit 1
      fi
      echo "ok: $what ($got)"
    }

    bump() { lock $new $sxold >flake.lock; }
    both() { lock $new $sxnew >flake.lock; }
    with() { lock $new $sxold | jq "$1" >flake.lock; }

    run pass "nixpkgs moved" "" bump
    run pass "nixpkgs and searxng moved" "" both
    # code is the reviews' business: any file may change
    code() { bump; echo y >vars/shared/value; echo '{ x = 1; }' >flake.nix; }
    run pass "a fix in vars/ and flake.nix" "" code
    # another input: any change needs a commit line naming it
    run fail "another input's rev moved, unexplained" "input node disko changed" \
      with '.nodes.disko.locked.rev = "4444444444444444444444444444444444444444"'
    run fail "another input's owner changed, unexplained" "input node disko changed" \
      with '.nodes.disko.locked.owner = "evil" | .nodes.disko.original.owner = "evil"'
    run fail "a new input node" "input node evil changed" \
      with '.nodes.evil = {original: {type: "github", owner: "x", repo: "y"}}'
    # a change the commit message names: the reviews judge it
    run pass "$(printf 'disko: use a fork\n\nflake.lock: node disko: upstream lacks the fix')" "" \
      with '.nodes.disko.locked.owner = "fork" | .nodes.disko.original.owner = "fork"'
    # a mention in passing names nothing (`foo.nix`, the bump's own line)
    run fail "machines/x/disko.nix: flake.lock: disko moved" "input node disko changed" \
      with '.nodes.disko.locked.rev = "4444444444444444444444444444444444444444"'
    # the rev stayed, the lock node did not
    same_rev() { lock $old $sxnew | jq ".nodes.nixpkgs_4.locked.narHash = \"sha256-$(printf 'C%.0s' {1..43})=\"" >flake.lock; }
    run fail "nixpkgs' narHash changed on the same rev" "nixpkgs's rev stayed but its lock node changed" same_rev
    run fail "root nixpkgs points elsewhere" "points at another node" \
      with '.nodes.root.inputs.nixpkgs = "disko"'
    run fail "a root input repointed, unexplained" "the root's inputs changed" \
      with '.nodes.root.inputs.disko = "nixpkgs_4"'
    run fail "root searxng a follows list" "root input searxng is not a plain node" \
      with '.nodes.root.inputs.searxng = ["nixpkgs"]'
    run fail "nixpkgs on another branch" "no longer follows github:NixOS/nixpkgs/nixpkgs-unstable" \
      with '.nodes.nixpkgs_4.original.ref = "nixos-unstable-small"'
    run fail "nixpkgs from another owner" "not a plain github:NixOS/nixpkgs rev" \
      with '.nodes.nixpkgs_4.locked.owner = "evil"'
    diverged() { bump; echo diverged >"$STUB/compare/NixOS/nixpkgs/$new...nixpkgs-unstable"; }
    run fail "a rev off nixpkgs-unstable (a fork's commit)" "is not on NixOS/nixpkgs nixpkgs-unstable" diverged
    behind() { bump; echo behind >"$STUB/compare/NixOS/nixpkgs/$old...$new"; }
    run fail "a rev older than main's" "does not descend from" behind
    offline() { bump; rm -rf "$STUB/compare"; }
    run fail "GitHub unreachable" "compare: unreachable" offline
    run fail "a wrong narHash" "narHash is not the prefetched one" \
      with ".nodes.nixpkgs_4.locked.narHash = \"sha256-$(printf 'C%.0s' {1..43})=\""
    sx_off() { both; echo diverged >"$STUB/compare/searxng/searxng/$sxnew...master"; }
    run fail "searxng off master" "searxng $sxnew is not on searxng/searxng master" sx_off
    run fail "searxng from a fork" "searxng no longer follows" \
      with '.nodes.searxng.original.owner = "evil" | .nodes.searxng.locked.owner = "evil"'
    # @ must be empty on top, and something must be pushed
    jj new main@origin >/dev/null 2>&1
    bump
    if nixpkgs-bump-guard >"$TMPDIR/out" 2>&1 || ! grep -q "FAIL: @ is not empty" "$TMPDIR/out"; then
      cat "$TMPDIR/out"; echo "FAILED: a non-empty @"; exit 1
    fi
    jj new main@origin >/dev/null 2>&1
    if nixpkgs-bump-guard >"$TMPDIR/out" 2>&1 || ! grep -q "FAIL: nothing on top" "$TMPDIR/out"; then
      cat "$TMPDIR/out"; echo "FAILED: nothing to push"; exit 1
    fi
    echo "ok: non-empty @ and nothing to push refused"
    echo ok >$out
  ''
