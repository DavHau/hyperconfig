# ./workspace.sh against a scratch colocated repository with a local
# origin (no network): create and remove a bump workspace twice in a row
# with no leftovers (create's stdout is the path alone); the overlap rule
# (a workspace, a directory, a symlink), failing listings refused; the
# mkdir lock (a same-name run that wins the race during the fetch is
# left alone); a failed create removing the workspace it made; remove on
# a half-made workspace, a symlink (only the link goes), unpushed work
# (refused, committed or not) and pushed work; names that are not bump
# names or are paths refused. The review's hardening: remove goes by
# path (a foreign workspace at the path, a bump-named workspace elsewhere,
# foreign content refused); a .jj symlinked or copied from the repository
# refused, default@ unchanged; a hostile JJ_CONFIG / ~/.config/jj (alias
# `empty()` = `all()`, nothing auto-tracked) does not make remove delete
# unpushed work; no --repo flag (the repository is fixed at build time).
{ pkgs }:
let
  # the test's variant; the guest's has the default repo
  helper = import ./workspace.nix {
    inherit pkgs;
    repo = "/build/top/hyperconfig";
    logDir = "/build/log";
  };
  production = import ./workspace.nix { inherit pkgs; };
in
pkgs.runCommand "nixpkgs-bump-workspace-test"
  {
    nativeBuildInputs = [
      helper
      pkgs.git
      pkgs.jujutsu
      pkgs.findutils
    ];
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR/home JJ_USER=test JJ_EMAIL=test@example.org
    mkdir -p $HOME /build/log
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main
    cd $TMPDIR
    git init -q --bare origin.git
    git init -q seed
    (cd seed && echo '{}' >flake.nix && echo '{}' >flake.lock && git add -A &&
      git commit -qm init && git push -q ../origin.git main)
    mkdir top && cd top
    jj git clone --colocate ../origin.git hyperconfig >/dev/null 2>&1
    repo=$PWD/hyperconfig
    [ "$repo" = /build/top/hyperconfig ] # the variant's repo
    # a stray file in the repository's working copy must not be committed
    echo stray >hyperconfig/stray.txt
    w() { nixpkgs-bump-workspace "$@"; }
    clean() { # no workspace, worktree, directory or worktree entry left
      [ "$(jj -R "$repo" --ignore-working-copy workspace list -T 'name ++ "\n"')" = default ]
      [ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" = 1 ]
      [ -z "$(find . -mindepth 1 -maxdepth 1 -name 'hyperconfig-nixpkgs-bump-*')" ]
      [ ! -e "$repo/.git/worktrees" ] || [ -z "$(ls -A "$repo/.git/worktrees")" ]
    }

    for n in 1 2; do
      ws=$(w create hyperconfig-nixpkgs-bump-test-$n 2>$TMPDIR/err)
      [ "$ws" = "$PWD/hyperconfig-nixpkgs-bump-test-$n" ] # stdout: the path alone
      grep -q "Created workspace in" $TMPDIR/err
      [ -f "$ws/flake.nix" ] && [ -f "$ws/.git" ]
      [ "$(jj -R "$ws" log --no-graph -r @- -T commit_id)" = "$(git -C "$repo" rev-parse main)" ]
      [ ! -e "$ws/stray.txt" ]
      [ -z "$(jj -R "$repo" --ignore-working-copy diff -r @ --name-only)" ]
      echo "ok: create $n"
      # the overlap rule: a second create touches nothing
      if w create hyperconfig-nixpkgs-bump-test-x 2>/dev/null; then echo "FAILED: overlap"; exit 1; fi
      [ ! -e hyperconfig-nixpkgs-bump-test-x ] && [ -d "$ws" ]
      echo "ok: overlap refused"
      echo r >/build/log/hyperconfig-nixpkgs-bump-test-$n.old-rev
      w remove hyperconfig-nixpkgs-bump-test-$n
      clean
      echo "ok: remove $n, no leftovers"
    done

    # the overlap rule sees a bare directory too
    mkdir hyperconfig-nixpkgs-bump-old
    if w create hyperconfig-nixpkgs-bump-test-3 2>/dev/null; then echo "FAILED: dir overlap"; exit 1; fi
    [ ! -e hyperconfig-nixpkgs-bump-test-3 ] && [ -d hyperconfig-nixpkgs-bump-old ]
    rmdir hyperconfig-nixpkgs-bump-old
    echo "ok: overlap with a directory refused, it is left alone"

    # ... and a symlink; remove of a symlink removes the link alone
    mkdir $TMPDIR/target && echo keep >$TMPDIR/target/f
    ln -s $TMPDIR/target hyperconfig-nixpkgs-bump-link
    if w create hyperconfig-nixpkgs-bump-test-3 2>/dev/null; then echo "FAILED: symlink overlap"; exit 1; fi
    [ ! -e hyperconfig-nixpkgs-bump-test-3 ] && [ -L hyperconfig-nixpkgs-bump-link ]
    w remove hyperconfig-nixpkgs-bump-link
    [ ! -L hyperconfig-nixpkgs-bump-link ] && [ "$(cat $TMPDIR/target/f)" = keep ]
    clean
    echo "ok: overlap with a symlink refused; remove drops only the link"

    # a listing that fails is a refusal: find (unreadable parent) ...
    chmod 311 .
    if w create hyperconfig-nixpkgs-bump-test-3 2>$TMPDIR/err; then echo "FAILED: find error ignored"; exit 1; fi
    chmod 755 .
    grep -q "FAIL: find in" $TMPDIR/err
    [ ! -e hyperconfig-nixpkgs-bump-test-3 ]
    # ... and jj (broken repository), for create and for remove
    mkdir hyperconfig-nixpkgs-bump-test-3
    mv "$repo/.jj/repo/op_heads" $TMPDIR/op_heads
    if w create hyperconfig-nixpkgs-bump-test-6 2>$TMPDIR/err; then echo "FAILED: jj error ignored"; exit 1; fi
    grep -q "FAIL: jj workspace list failed" $TMPDIR/err
    if w remove hyperconfig-nixpkgs-bump-test-3 2>$TMPDIR/err; then echo "FAILED: remove with jj broken"; exit 1; fi
    grep -q "FAIL: jj workspace list failed" $TMPDIR/err
    [ -d hyperconfig-nixpkgs-bump-test-3 ] && [ ! -e hyperconfig-nixpkgs-bump-test-6 ]
    mv $TMPDIR/op_heads "$repo/.jj/repo/op_heads"
    rmdir hyperconfig-nixpkgs-bump-test-3
    clean
    echo "ok: failing listings refused, nothing touched"

    # the mkdir lock: a same-name run that creates the directory while
    # this one fetches wins; this one exits 1 and leaves it alone
    git -C "$repo" config remote.origin.uploadpack "$TMPDIR/race.sh"
    printf '#!/bin/sh\nmkdir %s\nexec git-upload-pack "$@"\n' \
      "$PWD/hyperconfig-nixpkgs-bump-test-7" >$TMPDIR/race.sh
    chmod +x $TMPDIR/race.sh
    if w create hyperconfig-nixpkgs-bump-test-7 2>$TMPDIR/err; then echo "FAILED: lock"; exit 1; fi
    git -C "$repo" config --unset remote.origin.uploadpack
    grep -q "another run got there first" $TMPDIR/err
    ! grep -q "removing the workspace" $TMPDIR/err
    [ -d hyperconfig-nixpkgs-bump-test-7 ]
    rmdir hyperconfig-nixpkgs-bump-test-7
    clean
    echo "ok: mkdir lock, the winner is left alone"

    # a create that fails after `workspace add` and `jj new` (main@origin
    # has no flake.nix: no tree) removes the workspace and worktree it made
    (cd $TMPDIR/seed && git rm -q flake.nix && git commit -qm drop && git push -q ../origin.git main)
    if w create hyperconfig-nixpkgs-bump-test-4 2>$TMPDIR/err; then echo "FAILED: created without a tree"; exit 1; fi
    cat $TMPDIR/err
    grep -q "FAIL: no tree checked out" $TMPDIR/err
    grep -q "Created workspace in" $TMPDIR/err
    clean
    echo "ok: failed create cleaned up after itself"

    # remove works on a leftover of jj's failed add alone (no jj new)
    mkdir hyperconfig-nixpkgs-bump-test-5
    jj -R "$repo" --ignore-working-copy workspace add --colocate -r main@origin \
      hyperconfig-nixpkgs-bump-test-5 >/dev/null 2>&1 || true
    w remove hyperconfig-nixpkgs-bump-test-5
    clean
    echo "ok: remove clears a half-made workspace"

    # names outside the bump's, or paths, are refused
    mkdir -p $TMPDIR/x hyperconfig-nixpkgs-bump-.. && touch $TMPDIR/x/keep
    for n in hyperconfig ../x hyperconfig-nixpkgs-bump-../x; do
      if w remove "$n" 2>/dev/null; then echo "FAILED: removed $n"; exit 1; fi
    done
    rmdir hyperconfig-nixpkgs-bump-..
    for n in ../x hyperconfig-nixpkgs-bump-../x; do
      if w create "$n" 2>/dev/null; then echo "FAILED: created $n"; exit 1; fi
    done
    [ -d "$repo/.jj" ] && [ -f $TMPDIR/x/keep ] && [ ! -e $TMPDIR/x/.jj ]
    clean
    echo "ok: refuses other names and paths"

    # remove refuses unpushed work: uncommitted, then committed; after
    # the push it removes
    (cd $TMPDIR/seed && echo '{}' >flake.nix && git add -A && git commit -qm back &&
      git push -q ../origin.git main)
    ws=$(w create hyperconfig-nixpkgs-bump-test-8)
    echo bump >"$ws/flake.lock"
    if w remove hyperconfig-nixpkgs-bump-test-8 2>$TMPDIR/err; then echo "FAILED: removed uncommitted work"; exit 1; fi
    grep -q "has work not in main@origin" $TMPDIR/err
    [ "$(cat "$ws/flake.lock")" = bump ]
    (cd "$ws" && jj describe -m bump && jj new) >/dev/null 2>&1
    if w remove hyperconfig-nixpkgs-bump-test-8 2>$TMPDIR/err; then echo "FAILED: removed unpushed work"; exit 1; fi
    grep -q "has work not in main@origin" $TMPDIR/err
    [ "$(cat "$ws/flake.lock")" = bump ]
    echo "ok: remove refuses unpushed work"
    (cd "$ws" && jj bookmark set main -r @- && jj git push -b main) >/dev/null 2>&1
    w remove hyperconfig-nixpkgs-bump-test-8
    clean
    echo "ok: remove after the push"

    # --- the review's hardening ---
    jr() { jj -R "$repo" --ignore-working-copy "$@"; }
    default_at() { jr log --no-graph -r default@ -T commit_id; }

    # no --repo flag: usage error, nothing touched; the production
    # binary has the repository built in
    mkdir $TMPDIR/fake
    if w --repo $TMPDIR/fake create hyperconfig-nixpkgs-bump-test-9 2>$TMPDIR/err; then echo "FAILED: --repo accepted"; exit 1; fi
    grep -q "^usage:" $TMPDIR/err
    [ -z "$(ls -A $TMPDIR/fake)" ] && [ ! -e hyperconfig-nixpkgs-bump-test-9 ]
    grep -q "^repo=/home/infra/hyperconfig$" ${production}/bin/nixpkgs-bump-workspace
    ! grep -q -- "--repo" ${production}/bin/nixpkgs-bump-workspace
    clean
    echo "ok: no --repo flag; production repo built in"

    # remove goes by path: another jj workspace registered at the path ...
    mkdir hyperconfig-nixpkgs-bump-test-9
    jr workspace add --name other hyperconfig-nixpkgs-bump-test-9 >/dev/null 2>&1 || true
    echo keep >hyperconfig-nixpkgs-bump-test-9/keep
    if w remove hyperconfig-nixpkgs-bump-test-9 2>$TMPDIR/err; then echo "FAILED: removed a foreign workspace"; exit 1; fi
    grep -q "another jj workspace is at" $TMPDIR/err
    [ -f hyperconfig-nixpkgs-bump-test-9/keep ]
    jr workspace list -T 'name ++ "\n"' | grep -qx other
    jr workspace forget other && rm -rf hyperconfig-nixpkgs-bump-test-9
    # ... a bump-named workspace somewhere else (not forgotten, its git
    # worktree kept) ...
    mkdir $TMPDIR/elsewhere
    jr workspace add --colocate --name hyperconfig-nixpkgs-bump-test-10 $TMPDIR/elsewhere >/dev/null 2>&1 || true
    wt_before=$(git -C "$repo" worktree list --porcelain)
    if w remove hyperconfig-nixpkgs-bump-test-10 2>$TMPDIR/err; then echo "FAILED: removed a workspace elsewhere"; exit 1; fi
    grep -q "jj workspace hyperconfig-nixpkgs-bump-test-10 is not at" $TMPDIR/err
    jr workspace list -T 'name ++ "\n"' | grep -qx hyperconfig-nixpkgs-bump-test-10
    [ "$(git -C "$repo" worktree list --porcelain)" = "$wt_before" ] && [ -d $TMPDIR/elsewhere/.jj ]
    jr workspace forget hyperconfig-nixpkgs-bump-test-10 && rm -rf $TMPDIR/elsewhere
    git -C "$repo" worktree prune
    # ... and a directory that is no jj workspace: a foreign git repo,
    # a foreign jj repo, a stray file
    git init -q hyperconfig-nixpkgs-bump-test-11
    jj git init hyperconfig-nixpkgs-bump-test-12 >/dev/null 2>&1
    mkdir hyperconfig-nixpkgs-bump-test-13 && echo keep >hyperconfig-nixpkgs-bump-test-13/f
    for n in 11 12 13; do
      if w remove hyperconfig-nixpkgs-bump-test-$n 2>$TMPDIR/err; then echo "FAILED: removed foreign $n"; exit 1; fi
      grep -q "is no jj workspace hyperconfig-nixpkgs-bump-test-$n and not empty" $TMPDIR/err
      [ -d hyperconfig-nixpkgs-bump-test-$n ]
    done
    [ -d hyperconfig-nixpkgs-bump-test-11/.git ] && [ -d hyperconfig-nixpkgs-bump-test-12/.jj ]
    rm -rf hyperconfig-nixpkgs-bump-test-1[123]
    clean
    echo "ok: remove refuses a foreign workspace at the path, one elsewhere, foreign content"

    # a .jj symlinked (or copied) from the repository's: refused before
    # any snapshot, default@ and the workspace's files unchanged
    ws=$(w create hyperconfig-nixpkgs-bump-test-14)
    echo bump >"$ws/flake.lock"
    mv "$ws/.jj" $TMPDIR/ws14.jj
    ln -s "$repo/.jj" "$ws/.jj"
    before=$(default_at)
    if w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then echo "FAILED: removed via .jj symlink"; exit 1; fi
    grep -q "/.jj is not a real directory" $TMPDIR/err
    [ "$(default_at)" = "$before" ] && [ "$(cat "$ws/flake.lock")" = bump ]
    rm "$ws/.jj" && cp -r "$repo/.jj" "$ws/.jj"
    if w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then echo "FAILED: removed via copied .jj"; exit 1; fi
    grep -q "touching nothing" $TMPDIR/err
    [ "$(default_at)" = "$before" ] && [ "$(cat "$ws/flake.lock")" = bump ]
    rm -rf "$ws/.jj" && mv $TMPDIR/ws14.jj "$ws/.jj"
    ln -s "$repo/.jj/working_copy/tree_state" "$ws/.jj/working_copy/x"
    if w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then echo "FAILED: removed with a symlink in .jj"; exit 1; fi
    grep -q "a symlink in" $TMPDIR/err
    rm "$ws/.jj/working_copy/x"
    mv "$ws/.git" $TMPDIR/ws14.git && ln -s $TMPDIR/ws14.git "$ws/.git"
    if w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then echo "FAILED: removed with a .git symlink"; exit 1; fi
    grep -q "/.git is not a plain file" $TMPDIR/err
    rm "$ws/.git" && mv $TMPDIR/ws14.git "$ws/.git"
    [ "$(default_at)" = "$before" ]
    echo "ok: .jj / .git symlinks and a copied .jj refused, default@ unchanged"

    # a hostile jj config (JJ_CONFIG and ~/.config/jj) and git env do
    # not make remove delete the unpushed work in that same workspace
    printf '[revset-aliases]\n"empty()" = "all()"\n"main@origin" = "all()"\n[snapshot]\nauto-track = "none()"\n' >$TMPDIR/evil.toml
    mkdir -p $HOME/.config/jj && cp $TMPDIR/evil.toml $HOME/.config/jj/config.toml
    echo new >"$ws/untracked-new-file"
    if JJ_CONFIG=$TMPDIR/evil.toml GIT_DIR=$TMPDIR/fake w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then
      echo "FAILED: hostile config removed unpushed work"; exit 1
    fi
    grep -q "has work not in main@origin" $TMPDIR/err
    [ "$(cat "$ws/flake.lock")" = bump ] && [ -f "$ws/untracked-new-file" ]
    rm $HOME/.config/jj/config.toml
    # a new file alone (auto-track = none() would hide it): still refused
    (cd "$ws" && jj restore flake.lock) >/dev/null 2>&1
    if JJ_CONFIG=$TMPDIR/evil.toml w remove hyperconfig-nixpkgs-bump-test-14 2>$TMPDIR/err; then
      echo "FAILED: hostile config removed an untracked new file"; exit 1
    fi
    grep -q "has work not in main@origin" $TMPDIR/err && [ -f "$ws/untracked-new-file" ]
    echo "ok: hostile jj config does not make remove delete unpushed work"
    (cd "$ws" && jj abandon @) >/dev/null 2>&1
    [ ! -e "$ws/untracked-new-file" ]
    w remove hyperconfig-nixpkgs-bump-test-14
    clean
    echo "ok: removed once the work is gone"
    touch $out
  ''
