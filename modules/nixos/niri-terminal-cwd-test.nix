# Behavior test for niri-terminal-cwd: Mod+T opens a terminal in the working
# directory of the focused window's process.
#
# The script resolves `niri` and `alacritty` from the ambient PATH (same
# bare-name convention as the spaces command wrappers), so the test stubs both:
# the niri stub reports a controlled focused-window pid, the alacritty stub
# records the --working-directory it was launched with.
#
# Covered behavior:
#   1. focused window with a descendant process (terminal -> shell) whose cwd
#      is inside $HOME  -> terminal opens in that cwd
#   2. focused process cwd outside $HOME -> terminal opens in $HOME
#   3. no focused window (niri reports null) -> terminal opens in $HOME
#   4. niri unavailable/failing -> terminal opens in $HOME
{ pkgs }:
let
  script = import ./niri-terminal-cwd-package.nix { inherit pkgs; };
in
pkgs.runCommand "niri-terminal-cwd-test" { } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME/projects/demo"
  mkdir -p "$TMPDIR/bin" "$TMPDIR/outside"

  # --- stubs ------------------------------------------------------------
  # alacritty: record the working directory it was asked to start in.
  cat > "$TMPDIR/bin/alacritty" <<'EOF'
  #!/bin/sh
  [ "$1" = "--working-directory" ] || { echo "unexpected args: $*" >&2; exit 1; }
  printf '%s' "$2" > "$RESULT"
  EOF
  # niri: pretend the window whose pid is $FOCUSED_PID is focused.
  cat > "$TMPDIR/bin/niri" <<'EOF'
  #!/bin/sh
  [ "$1" = "msg" ] || exit 1
  if [ -n "$FOCUSED_PID" ]; then
    printf '{"id":1,"title":"t","pid":%s}\n' "$FOCUSED_PID"
  else
    printf 'null\n'
  fi
  EOF
  chmod +x "$TMPDIR/bin/alacritty" "$TMPDIR/bin/niri"
  export PATH="$TMPDIR/bin:$PATH"
  export RESULT="$TMPDIR/result"

  run() { ${script}/bin/niri-terminal-cwd; cat "$RESULT"; }

  # --- 1: descendant cwd inside $HOME ------------------------------------
  # Process tree mimicking terminal -> shell: parent bash whose child sleeps
  # inside $HOME/projects/demo. Focused pid = parent; the script must walk to
  # the descendant and pick up ITS cwd.
  bash -c "cd '$HOME/projects/demo' && sleep 60 & wait" &
  parent=$!
  # wait for the sleep child to exist
  for _ in $(seq 50); do pgrep -P "$parent" > /dev/null 2>&1 && break; sleep 0.1; done

  got=$(FOCUSED_PID=$parent run)
  [ "$got" = "$HOME/projects/demo" ] || { echo "case 1: expected $HOME/projects/demo, got: $got"; exit 1; }
  kill "$parent" 2>/dev/null || true

  # --- 2: cwd outside $HOME -> $HOME --------------------------------------
  ( cd "$TMPDIR/outside" && exec sleep 60 ) &
  outsider=$!
  got=$(FOCUSED_PID=$outsider run)
  [ "$got" = "$HOME" ] || { echo "case 2: expected $HOME, got: $got"; exit 1; }
  kill "$outsider" 2>/dev/null || true

  # --- 3: no focused window -> $HOME ---------------------------------------
  got=$(FOCUSED_PID= run)
  [ "$got" = "$HOME" ] || { echo "case 3: expected $HOME, got: $got"; exit 1; }

  # --- 4: niri failing -> $HOME ---------------------------------------------
  cat > "$TMPDIR/bin/niri" <<'EOF'
  #!/bin/sh
  exit 1
  EOF
  chmod +x "$TMPDIR/bin/niri"
  got=$(run)
  [ "$got" = "$HOME" ] || { echo "case 4: expected $HOME, got: $got"; exit 1; }

  touch $out
''
