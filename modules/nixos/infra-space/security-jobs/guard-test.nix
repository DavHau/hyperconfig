# Offline scratch-repo tests of the security-job allowlist, movable-input
# ancestry and the exact-commit privileged push. Network is replaced by the
# ancestry stub; protected.nix evaluation by its argument-logging stub.
{ pkgs }:
let
  protectedStub = pkgs.writeShellScriptBin "sec-job-protected-check" ''
    echo "$@" >>"$TMPDIR/protected-calls"
    [ ! -e "$TMPDIR/protected-fail" ] || { echo "stub: protected settings differ" >&2; exit 1; }
    echo "protected: no difference (stub)"
  '';
  ancestryStub = pkgs.writeShellScriptBin "sec-job-input-ancestry" ''
    echo "$1" >>"$TMPDIR/ancestry-calls"
    # all-f is the test's fork-only object, not on the tracked ref
    if jq -e --arg n "$1" '.nodes[$n].locked.rev == "ffffffffffffffffffffffffffffffffffffffff"' "$3" >/dev/null; then
      echo "stub: $1 does not descend from its tracked ref" >&2
      exit 1
    fi
    echo "ancestry: $1 descends (stub)"
  '';
  guard = pkgs.writeShellApplication {
    name = "sec-job-guard";
    runtimeInputs = [
      pkgs.coreutils pkgs.git pkgs.gnugrep pkgs.gawk pkgs.jq pkgs.jujutsu
      protectedStub ancestryStub
    ];
    text = builtins.readFile ./guard.sh;
  };
  # the real ancestry check, against local origins under /build
  ancestry = pkgs.writeShellApplication {
    name = "sec-job-input-ancestry-real";
    runtimeInputs = [ pkgs.coreutils pkgs.git pkgs.jq ];
    text = builtins.replaceStrings [ "@testRoot@" ] [ "/build" ] (builtins.readFile ./input-ancestry.sh);
  };
  push = pkgs.writeShellApplication {
    name = "sec-job-push";
    runtimeInputs = [ pkgs.coreutils pkgs.git ];
    text = builtins.replaceStrings
      [ "@jobs@" "@spool@" "@origin@" "@scratchRoot@" "@guard@" ]
      [ "cve-watch hygiene-report security-audit" "/build/spool" "/build/origin.git" "/build/push" "${guard}/bin/sec-job-guard" ]
      (builtins.readFile ./push.sh);
  };
in
pkgs.runCommand "sec-job-guard-test"
  { nativeBuildInputs = [ guard push ancestry pkgs.git pkgs.jujutsu pkgs.jq ]; }
  ''
    set -euo pipefail
    export HOME=$TMPDIR/home JJ_USER=test JJ_EMAIL=test@example.org
    mkdir -p $HOME /build/spool /build/push
    git config --global user.name test
    git config --global user.email test@example.org
    git config --global init.defaultBranch main
    cd $TMPDIR
    git init -q --bare /build/origin.git
    git init -q seed
    (
      cd seed
      mkdir -p modules/nixos/infra-space modules/nixos/foo modules/nixos/security-fixes vars/per-machine/som/x
      jq -n '{nodes: {
        root: {inputs: {nixpkgs: "nixpkgs", afk: "afk", teamclaude: "teamclaude", ncps: "ncps", srvos: "srvos", "clan-core": "clan-core"}},
        nixpkgs: {locked: {rev: "1"}, original: {type: "github", owner: "NixOS", repo: "nixpkgs"}},
        afk: {inputs: {"flake-utils": "flake-utils", nixpkgs: ["nixpkgs"]}, locked: {rev: "1"}, original: {type: "github", owner: "a", repo: "afk", ref: "main"}},
        "flake-utils": {locked: {rev: "1"}, original: {type: "github", owner: "f", repo: "u"}},
        teamclaude: {locked: {rev: "1"}, original: {type: "github", owner: "t", repo: "t"}},
        ncps: {locked: {rev: "1"}, original: {type: "git", url: "https://example/ncps"}},
        srvos: {inputs: {nixpkgs: ["nixpkgs"]}, locked: {rev: "1"}, original: {type: "github", owner: "nix-community", repo: "srvos"}},
        "clan-core": {inputs: {nixpkgs: ["nixpkgs"]}, locked: {rev: "1"}, original: {type: "git", url: "https://git.clan.lol/clan/clan-core"}}
      }, root: "root", version: 7}' >flake.lock
      printf '{\n  users.users.dave.extraGroups = [\n    "wheel"\n    "video"\n  ];\n  users.users.dave.hashedPassword = "x";\n}\n' >modules/nixos/foo/users.nix
      echo '{ }' >flake.nix
      printf '{\n  services.foo.enable = true;\n  a = 1;\n  b = 1;\n  c = 1;\n  d = 1;\n  networking.firewall.allowedTCPPorts = [\n    22\n    8443\n  ];\n}\n' >modules/nixos/foo/default.nix
      echo '{ }' >modules/nixos/infra-space/default.nix
      echo '{ }' >modules/nixos/security-fixes.nix
      echo '[ ]' >modules/nixos/security-fixes/overlays.nix
      mkdir -p modules/nixos/security-takedown
      echo '{}' >modules/nixos/security-takedown/takedowns.json
      echo x >vars/per-machine/som/x/value
      git add -A && git commit -qm init && git push -q /build/origin.git main
    )
    jj git clone --colocate /build/origin.git hyperconfig-sec-cve-watch-test >/dev/null 2>&1
    cd hyperconfig-sec-cve-watch-test
    base=$(jj log --no-graph -r main@origin -T commit_id)

    case_() {
      local name=$1 expect=$2
      shift 2
      jj new -q "$base" 2>/dev/null || jj new "$base" >/dev/null 2>&1
      sh -c "$*"
      jj describe -m "test: $name" >/dev/null 2>&1
      set +e
      sec-job-guard --offline >$TMPDIR/out 2>&1
      rc=$?
      set -e
      if [ "$expect" = pass ]; then
        [ $rc = 3 ] && tail -n 1 $TMPDIR/out | grep -qx 'sec-job-guard: PASS-OFFLINE (not a permit)' ||
          { echo "case $name: expected PASS-OFFLINE, got $rc"; cat $TMPDIR/out; exit 1; }
      else
        [ $rc = 1 ] || { echo "case $name: expected FAIL, got $rc"; cat $TMPDIR/out; exit 1; }
      fi
      echo "ok $name ($expect)"
    }

    # Positive allowlist: arbitrary module edits (previously accepted) fail;
    # takedowns, the fixes module and one patch, and movable locks pass.
    case_ outside-allowlist fail 'sed -i "s/services.foo.enable = true;/services.foo.enable = true;\n  services.foo.package = pkgs.foo_2;/" modules/nixos/foo/default.nix'
    case_ takedown pass 'echo "{\"som\": {\"foo.service\": {\"reason\": \"x\", \"since\": \"2026-11-15\", \"undo\": \"y\"}}}" >modules/nixos/security-takedown/takedowns.json'
    case_ fixes-overlay pass 'echo "[ (final: prev: { }) ]" >modules/nixos/security-fixes/overlays.nix'
    # the fleet-wide wrapper is fixed: no NixOS option through it
    case_ fixes-wrapper fail 'echo "{ pkgs, ... }: { nixpkgs.overlays = [ ]; }" >modules/nixos/security-fixes.nix'
    case_ takedown-nix fail 'echo "{ }" >modules/nixos/security-takedown/takedowns.nix'
    case_ fixes-patch pass 'mkdir -p modules/nixos/security-fixes && echo "--- a/x" >modules/nixos/security-fixes/CVE-2026-1.patch'
    case_ nested-patch fail 'mkdir -p modules/nixos/security-fixes/nested && echo x >modules/nixos/security-fixes/nested/x.patch'
    case_ symlink-fix fail 'mkdir -p modules/nixos/security-fixes && ln -s /etc/passwd modules/nixos/security-fixes/x.patch'
    case_ lock-move pass 'jq ".nodes.afk.locked.rev = \"2\" | .nodes[\"flake-utils\"].locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    grep -qx afk $TMPDIR/ancestry-calls
    grep -qx flake-utils $TMPDIR/ancestry-calls
    case_ lock-nixpkgs fail 'jq ".nodes.nixpkgs.locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    case_ lock-srvos fail 'jq ".nodes.srvos.locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    case_ lock-clan-core fail 'jq ".nodes[\"clan-core\"].locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    case_ lock-teamclaude fail 'jq ".nodes.teamclaude.locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    case_ lock-ncps fail 'jq ".nodes.ncps.locked.rev = \"2\"" flake.lock >l && mv l flake.lock'
    case_ lock-new-node fail 'jq ".nodes.evil = {locked: {}, original: {type: \"github\", owner: \"e\", repo: \"e\"}} | .nodes.root.inputs.evil = \"evil\"" flake.lock >l && mv l flake.lock'
    case_ lock-original fail 'jq ".nodes.afk.original.owner = \"evil\"" flake.lock >l && mv l flake.lock'
    case_ lock-fork-rev fail 'jq ".nodes.afk.locked.rev = \"ffffffffffffffffffffffffffffffffffffffff\"" flake.lock >l && mv l flake.lock'
    grep -q 'does not descend' $TMPDIR/out

    # The allowlist is primary: every old bypass/path case is still refused.
    case_ vars fail 'echo y >vars/per-machine/som/x/value'
    case_ own-module fail 'echo "{ x = 1; }" >modules/nixos/infra-space/default.nix'
    case_ flake-nix fail 'echo "{ inputs = { }; }" >flake.nix'
    case_ hyperhermes fail 'mkdir -p hyperhermes && echo "{ }" >hyperhermes/x.nix'
    case_ skills fail 'mkdir -p skills/x && echo evil >skills/x/SKILL.md'
    case_ agents fail 'echo x >AGENTS.md'
    case_ open-port fail 'sed -i "s/services.foo.enable = true;/services.foo.enable = true;\n  networking.firewall.allowedUDPPorts = [ 53 ];/" modules/nixos/foo/default.nix'
    case_ sshd-off fail 'sed -i "s/services.foo.enable = true;/services.foo.enable = false;/" modules/nixos/foo/default.nix'
    case_ eligible fail 'mkdir -p modules/nixos/security-takedown && echo "{ }" >modules/nixos/security-takedown/eligible.nix'
    case_ protected-fix-line fail 'echo "[ (final: prev: { }) ] // { services.openssh.enable = false; }" >modules/nixos/security-fixes/overlays.nix'
    case_ trust-fix-line fail 'echo "[ ] ++ [ { nix.settings.trusted-users = [ \"infra-jobs\" ]; } ]" >modules/nixos/security-fixes/overlays.nix'
    case_ two-takedowns fail 'echo "{\"som\": {\"foo.service\": {\"reason\": \"x\", \"since\": \"d\", \"undo\": \"y\"}, \"bar.service\": {\"reason\": \"x\", \"since\": \"d\", \"undo\": \"y\"}}}" >modules/nixos/security-takedown/takedowns.json'
    case_ takedown-not-data fail 'echo "{\"som\": [\"foo.service\", \"bar.service\"]}" >modules/nixos/security-takedown/takedowns.json'

    jj new "$base" >/dev/null 2>&1
    echo '[ (final: prev: { }) ]' >modules/nixos/security-fixes/overlays.nix
    jj describe -m 'test: online' >/dev/null 2>&1
    sec-job-guard | tail -n 1 | grep -qx 'sec-job-guard: PASS'
    grep -qx "$base $(jj log --no-graph -r @ -T commit_id) $(pwd -P)" $TMPDIR/protected-calls
    echo 'ok online-pass'
    touch $TMPDIR/protected-fail
    ! sec-job-guard >$TMPDIR/out 2>&1
    grep -q 'evaluated protected settings differ' $TMPDIR/out
    rm $TMPDIR/protected-fail
    echo 'ok online-protected-fail'

    # Push the bundled id, not the subsequently changed job working copy.
    rev=$(jj log --no-graph -r @ -T commit_id)
    git update-ref refs/sec-job-push/$rev "$rev"
    git bundle create /build/spool/cve-watch-$rev.bundle refs/sec-job-push/$rev --not origin/main
    git update-ref -d refs/sec-job-push/$rev
    jj new >/dev/null 2>&1
    echo '[ (final: prev: { changed_after_bundle = true; }) ]' >modules/nixos/security-fixes/overlays.nix
    jj describe -m 'test: later working-copy change' >/dev/null 2>&1
    later=$(jj log --no-graph -r @ -T commit_id)
    [ "$later" != "$rev" ]
    sec-job-push cve-watch "$rev" >$TMPDIR/push.out
    grep -q 'sec-job-guard: PASS' $TMPDIR/push.out
    grep -qx "sec-job-push: pushed $rev to main" <(tail -n 1 $TMPDIR/push.out)
    [ "$(git --git-dir=/build/origin.git rev-parse refs/heads/main)" = "$rev" ]
    [ "$(git --git-dir=/build/origin.git rev-parse refs/heads/main)" != "$later" ]
    echo 'ok exact-commit-push-after-working-copy-moved'

    ! sec-job-push cve-watch short >/dev/null 2>&1
    ! sec-job-push other "$rev" >/dev/null 2>&1
    ! sec-job-push ../cve-watch "$rev" >/dev/null 2>&1
    echo 'ok push-argument-validation'
    # The real ancestry check: the new rev must be on the tracked ref's
    # history and descend from the current lock.
    git init -q --bare /build/up.git
    git init -q up && cd up
    c() { git commit -q --allow-empty -m "$1" && git rev-parse HEAD; }
    a=$(c a); b=$(c b); tipc=$(c tip)
    git push -q /build/up.git HEAD:refs/heads/main
    git checkout -q -b side "$a"; s=$(c side)
    git push -q /build/up.git side:refs/heads/side
    cd ..
    lock() { jq -n --arg r "$1" '{nodes: {x: {locked: {rev: $r}, original: {type: "git", url: "/build/up.git", ref: "main"}}}}' >"$2"; }
    lock "$b" old.json
    expect() { # pass|fail NEW-REV
      lock "$2" new.json
      if sec-job-input-ancestry-real x old.json new.json >$TMPDIR/anc 2>&1; then r=pass; else r=fail; fi
      [ "$r" = "$1" ] || { echo "ancestry $2: expected $1"; cat $TMPDIR/anc; exit 1; }
    }
    expect pass "$tipc"   # forward along main
    expect pass "$b"      # unchanged
    expect fail "$a"      # a downgrade
    expect fail "$s"      # a side branch the remote also serves
    expect fail ffffffffffffffffffffffffffffffffffffffff
    lock "$tipc" new.json
    jq '.nodes.x.original.url = "/elsewhere/up.git"' new.json >n && mv n new.json
    ! sec-job-input-ancestry-real x old.json new.json >/dev/null 2>&1
    echo 'ok real-ancestry'

    touch $out
  ''
