# greetd-idle-restart.sh (greetd.nix) against fake inputs: mock
# systemctl and loginctl on PATH, a fake /proc/<pid> (exe symlink,
# cmdline) via GREETD_IDLE_RESTART_PROC. Session JSON shaped like som's
# live `loginctl list-sessions --json=short` (seatless manager sessions,
# the greeter on seat0, State "active").
# `units` (optional): a machine's rendered systemd.units, to assert the
# services carry no start limit.
{
  pkgs,
  units ? null,
}:
let
  inherit (pkgs) lib;
  unitChecks = lib.optionals (units != null) (
    map (
      u:
      assert lib.assertMsg (lib.hasInfix "StartLimitIntervalSec=0" units.${u}.text)
        "${u}: StartLimitIntervalSec=0 missing";
      assert lib.assertMsg (lib.hasInfix "TimeoutStartSec=30s" units.${u}.text)
        "${u}: TimeoutStartSec=30s missing";
      u
    ) [ "greetd-idle-restart.service" "greetd-idle-restart-check.service" ]
  );
  script = pkgs.writeShellScript "greetd-idle-restart" (builtins.readFile ./greetd-idle-restart.sh);
  newExe = "/nix/store/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn-greetd-0.10.3/bin/greetd";
  oldExe = "/nix/store/oooooooooooooooooooooooooooooooo-greetd-0.10.3/bin/greetd";
  newToml = "/nix/store/tttttttttttttttttttttttttttttttt-greetd.toml";
  oldToml = "/nix/store/uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu-greetd.toml";
in
pkgs.runCommand "greetd-idle-restart-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.gnused
      pkgs.coreutils
      pkgs.findutils
    ];
  }
  ''
    set -u
    echo "unit assertions: ${toString unitChecks}"
    mkdir -p bin
    cat > bin/systemctl <<'EOF'
    #!${pkgs.runtimeShell}
    case "$*" in
      "is-active -q greetd.service") exit "''${FAKE_ACTIVE:-0}" ;;
      "show -p MainPID --value greetd.service") echo "''${FAKE_PID-42}" ;;
      "show -p ExecStart --value greetd.service")
        [ -n "''${FAKE_SHOW_FAIL:-}" ] && exit 1
        echo "{ path=${newExe} ; argv[]=${newExe} --config ${newToml} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" ;;
      "restart --no-block greetd.service") echo restart >> "$CALLS" ;;
      *) echo "unexpected systemctl $*" >&2; exit 1 ;;
    esac
    EOF
    cat > bin/loginctl <<'EOF'
    #!${pkgs.runtimeShell}
    case "$1" in
      list-sessions)
        [ -n "''${FAKE_LOGINCTL_FAIL:-}" ] && { echo "Failed to connect to bus" >&2; exit 1; }
        # From the second call on (the re-check), FAKE_SESSIONS_LATER if set.
        n=$(cat "$FAKE_SESSIONS.n" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_SESSIONS.n"
        if [ "$n" -ge 1 ] && [ -n "''${FAKE_SESSIONS_LATER:-}" ]; then
          cat "$FAKE_SESSIONS_LATER"
        else
          cat "$FAKE_SESSIONS"
        fi ;;
      show-session)
        [ -n "''${FAKE_SHOW_SESSION_FAIL:-}" ] && { echo "Failed to get session" >&2; exit 1; }
        v="FAKE_STATE_$5"; echo "''${!v:-active}" ;;
      *) exit 1 ;;
    esac
    EOF
    chmod +x bin/*
    export PATH=$PWD/bin:$PATH

    idle='[{"session":"45080","uid":997,"user":"greeter","seat":null,"class":"manager-early"},{"session":"57840","uid":1000,"user":"dave","seat":null,"class":"manager"},{"session":"90670","uid":997,"user":"greeter","seat":"seat0","class":"greeter","tty":"tty1"}]'
    # Mid-login: the greeter's session is gone, the user's not there yet.
    nogreeter='[{"session":"45080","uid":997,"user":"greeter","seat":null,"class":"manager-early"},{"session":"57840","uid":1000,"user":"dave","seat":null,"class":"manager"}]'
    printf '%s' "$nogreeter" > nogreeter.json
    # Just logged out: the new greeter is up, the user's session lingers.
    loggedout='[{"session":"57840","uid":1000,"user":"dave","seat":null,"class":"manager"},{"session":"7","uid":1000,"user":"dave","seat":"seat0","class":"user","tty":"tty1"},{"session":"90670","uid":997,"user":"greeter","seat":"seat0","class":"greeter","tty":"tty1"}]'
    busy='[{"session":"57840","uid":1000,"user":"dave","seat":null,"class":"manager"},{"session":"7","uid":1000,"user":"dave","seat":"seat0","class":"user","tty":"tty1"}]'

    # run <name> <expect restart: yes|no> <exe> <cmdline> <sessions>
    run() {
      name=$1 want=$2 exe=$3 cmd=$4 sessions=$5
      rm -rf proc && mkdir -p proc/42
      ln -s "$exe" proc/42/exe
      printf '%s' "$cmd" | tr ' ' '\0' > proc/42/cmdline
      printf '%s' "$sessions" > sessions.json
      export CALLS=$PWD/calls FAKE_SESSIONS=$PWD/sessions.json GREETD_IDLE_RESTART_PROC=$PWD/proc
      rm -f calls stamp sessions.json.n
      [ -n "''${OLD_STAMP:-}" ] && touch -d '20 minutes ago' stamp
      export GREETD_IDLE_RESTART_STAMP=$PWD/stamp GREETD_IDLE_RESTART_RECHECK_DELAY=0
      rc=0; ${script} ''${ARGS:-} > log 2>&1 || rc=$?
      got=no; [ -e calls ] && got=yes
      sed "s/^/  [$name] /" log
      if [ "$rc" != 0 ] || [ "$got" != "$want" ]; then
        echo "FAIL $name: exit=$rc restart=$got, want exit=0 restart=$want"; exit 1
      fi
      if [ -n "''${WANT_SILENT:-}" ] && [ -s log ]; then
        echo "FAIL $name: --quiet printed output"; exit 1
      fi
      echo "ok   $name (restart=$got)"
    }

    run old-greetd-idle-seat       yes "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    run old-greetd-deleted-exe     yes "${oldExe} (deleted)" "${oldExe} --config ${oldToml}" "$idle"
    run same-exe-other-config      yes "${newExe}" "${newExe} --config ${oldToml}" "$idle"
    run old-greetd-user-session    no  "${oldExe}" "${oldExe} --config ${oldToml}" "$busy"
    FAKE_STATE_7=closing \
    run old-greetd-session-closing yes "${oldExe}" "${oldExe} --config ${oldToml}" "$loggedout"
    FAKE_STATE_7=online \
    run old-greetd-session-online  no  "${oldExe}" "${oldExe} --config ${oldToml}" "$busy"
    FAKE_STATE_7=online \
    run logged-out-session-online  no  "${oldExe}" "${oldExe} --config ${oldToml}" "$loggedout"
    run current-greetd             no  "${newExe}" "${newExe} --config ${newToml}" "$idle"
    run executor-at-boot           no  "/nix/store/ssssssssssssssssssssssssssssssss-systemd-262/lib/systemd/systemd-executor" \
      "/nix/store/ssssssssssssssssssssssssssssssss-systemd-262/lib/systemd/systemd-executor --deserialize 3" "$idle"
    FAKE_LOGINCTL_FAIL=1 \
    run loginctl-fails             no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    run sessions-not-json          no  "${oldExe}" "${oldExe} --config ${oldToml}" "not json"
    FAKE_SHOW_FAIL=1 \
    run systemctl-show-fails       no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    FAKE_PID=0 \
    run no-main-pid                no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    FAKE_ACTIVE=3 \
    run greetd-inactive            no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    FAKE_SHOW_SESSION_FAIL=1 \
    run show-session-fails         no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    run no-greeter-mid-login       no  "${oldExe}" "${oldExe} --config ${oldToml}" "$nogreeter"
    FAKE_STATE_90670=closing \
    run greeter-closing            no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    FAKE_SESSIONS_LATER=$PWD/nogreeter.json \
    run greeter-gone-at-recheck    no  "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    OLD_STAMP=1 \
    run stamp-expired              yes "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    ARGS=--quiet WANT_SILENT=1 \
    run quiet-current              no  "${newExe}" "${newExe} --config ${newToml}" "$idle"
    ARGS=--quiet WANT_SILENT=1 \
    run quiet-busy                 no  "${oldExe}" "${oldExe} --config ${oldToml}" "$busy"
    ARGS=--quiet WANT_SILENT=1 \
    run quiet-mid-login            no  "${oldExe}" "${oldExe} --config ${oldToml}" "$nogreeter"
    # Loop guard: a second stale run right after a restart does nothing.
    run first-restart yes "${oldExe}" "${oldExe} --config ${oldToml}" "$idle"
    rm -f sessions.json.n; ${script} > log 2>&1; rc=$?
    [ "$rc" = 0 ] && [ "$(wc -l < calls)" = 1 ] || { echo "FAIL loop-guard: exit=$rc"; cat log; exit 1; }
    cat log; echo "ok   loop-guard (no second restart)"
    # greetd exited between the checks: /proc/<pid> is gone.
    rm -rf proc calls stamp; mkdir proc
    rc=0; GREETD_IDLE_RESTART_PROC=$PWD/proc ${script} > log 2>&1 || rc=$?
    [ "$rc" = 0 ] && [ ! -e calls ] || { echo "FAIL pid-gone: exit=$rc"; cat log; exit 1; }
    echo "ok   pid-gone"
    touch $out
  ''
