# Sandboxed regression test + screenshot harness for the ssh-tpm-agent confirm
# dialog (see ssh-tpm-confirm-dialog.py).
#
#   nix build .#checks.x86_64-linux.ssh-tpm-confirm-dialog
#   $(nix path-info ...)/  ->  rows-4.png, rows-12.png, keyboard.png, answers
#
# Everything runs inside the nix build sandbox on a private Xvfb: no access to
# the user's session, display, or ssh-agent. The dialog under test is the exact
# derivation the NixOS module installs.
#
# Asserted behaviour:
#   * the window is tall enough to show every ancestry row without scrolling
#   * Return / KP_Enter / space / Tab cannot commit a grant (the bug: a stray
#     Return while typing used to approve the dialog the instant it appeared)
#   * Escape denies
#   * mouse clicks on the buttons still work, and pick the selected row
{ pkgs }:
let
  dialog = import ./ssh-tpm-confirm-dialog.nix { inherit pkgs; };

  # Layout constants mirrored from ssh-tpm-confirm-dialog.py, used both to
  # compute where the buttons are (for synthetic clicks) and to assert the
  # window is content-sized.
  rowHeight = 30;
  chromeHeight = 165;
  buttonWidth = 150;
  buttonSpacing = 8;
  margin = 16;
in
pkgs.runCommand "ssh-tpm-confirm-dialog-test"
{
  nativeBuildInputs = [
    pkgs.xorg.xorgserver
    pkgs.xdotool
    pkgs.xorg.xwininfo
    pkgs.imagemagick
    pkgs.procps
  ];
  # Without a font config the sandboxed dialog renders blank text, which would
  # make the screenshots useless.
  FONTCONFIG_FILE = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.dejavu_fonts pkgs.liberation_ttf ];
  };
} ''
  set -euo pipefail
  mkdir -p $out
  export HOME=$TMPDIR
  export XDG_RUNTIME_DIR=$TMPDIR
  export GSETTINGS_BACKEND=memory
  export DISPLAY=:97

  Xvfb $DISPLAY -screen 0 1600x1000x24 >/dev/null 2>&1 &
  xvfb_pid=$!
  trap 'kill $xvfb_pid 2>/dev/null || true' EXIT
  for _ in $(seq 1 300); do
    if xdotool getdisplaygeometry >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  xdotool getdisplaygeometry >/dev/null

  # A plausible ancestry: requester first, then its parents up to systemd,
  # including the deep project cwd that made the old yad dialog scroll.
  names=(ssh git nix-daemon bash tmux niri systemd)
  dirs=(
    /home/alice/projects/hyperconfig
    /home/alice/projects/hyperconfig/modules/nixos
    ""
    /home/alice
    /home/alice
    /
    /
  )
  make_choices() { # $1 = row count -> stdout
    local i n d
    for i in $(seq 0 $(($1 - 1))); do
      n="''${names[$((i % ''${#names[@]}))]}"
      d="''${dirs[$((i % ''${#dirs[@]}))]}"
      printf '%s\t%s\t%s\n' "$((4242 - i))" "$n" "$d"
    done
  }

  start_dialog() { # $1 = row count, $2 = answer file
    SSH_TPM_CHOICES="$(make_choices "$1")" \
    SSH_TPM_CONFIRM_TTL=15m \
      ${dialog}/bin/ssh-tpm-confirm-dialog \
        "ssh-tpm-agent: authorise SSH key id_tpm (testkey)?" > "$2" &
    dialog_pid=$!
    for _ in $(seq 1 300); do
      if xdotool search --name '^ssh-tpm-agent$' >/dev/null 2>&1; then break; fi
      sleep 0.1
    done
    win="$(xdotool search --name '^ssh-tpm-agent$' | head -n1)"
    xdotool windowactivate --sync "$win" 2>/dev/null || true
    sleep 1
  }

  win_geom() { # sets WIN_X WIN_Y WIN_W WIN_H
    eval "$(xwininfo -id "$win" | sed -n \
      -e 's/^ *Absolute upper-left X: *\(.*\)/WIN_X=\1/p' \
      -e 's/^ *Absolute upper-left Y: *\(.*\)/WIN_Y=\1/p' \
      -e 's/^ *Width: *\(.*\)/WIN_W=\1/p' \
      -e 's/^ *Height: *\(.*\)/WIN_H=\1/p')"
  }

  # Buttons are right-aligned on the last row: [Deny][Trust ttl][Trust forever].
  click_button() { # $1 = 0 (Deny) | 1 (Trust ttl) | 2 (Trust forever)
    win_geom
    local slot=$((2 - $1))
    local cx=$((WIN_X + WIN_W - ${toString margin} \
      - slot * (${toString buttonWidth} + ${toString buttonSpacing}) \
      - ${toString buttonWidth} / 2))
    local cy=$((WIN_Y + WIN_H - ${toString margin} - 20))
    xdotool mousemove --sync "$cx" "$cy" click 1
    sleep 1
  }

  ###########################################################################
  echo "== case 1: 4 rows fit without scrolling, mouse click grants =="
  start_dialog 4 $out/answer-rows-4
  win_geom
  magick import -window "$win" $out/rows-4.png
  want=$((${toString chromeHeight} + 4 * ${toString rowHeight}))
  echo "window ''${WIN_W}x''${WIN_H}, want height >= $want" | tee $out/geometry-rows-4
  if [ "$WIN_H" -lt "$want" ]; then
    echo "FAIL: window too short for 4 rows (''${WIN_H} < $want)" >&2
    exit 1
  fi
  # No row click: the requester (row 0) is preselected, so a plain mouse click
  # on "Trust 15m" must grant exactly that pid.
  click_button 1
  wait $dialog_pid || true
  echo "answer: $(cat $out/answer-rows-4)"
  grep -qx 'temporary 4242' $out/answer-rows-4 \
    || { echo "FAIL: mouse grant on the preselected row" >&2; exit 1; }

  ###########################################################################
  echo "== case 2: 12 rows, capped at 80% of the 1000px screen =="
  start_dialog 12 $out/answer-rows-12
  win_geom
  magick import -window "$win" $out/rows-12.png
  echo "window ''${WIN_W}x''${WIN_H}" | tee $out/geometry-rows-12
  if [ "$WIN_H" -gt 800 ]; then
    echo "FAIL: window exceeds the 80% workarea cap (''${WIN_H} > 800)" >&2
    exit 1
  fi
  want=$((${toString chromeHeight} + 12 * ${toString rowHeight}))
  if [ "$WIN_H" -lt "$want" ]; then
    echo "FAIL: window did not grow with the row count (''${WIN_H} < $want)" >&2
    exit 1
  fi

  # Mouse row selection: two clicks at different heights inside the list must
  # target two different ancestors. Exact row origins are font-dependent, so
  # the assertion is "different y -> different pid", not a pinned pid.
  xdotool mousemove --sync $((WIN_X + WIN_W / 2)) $((WIN_Y + 160)) click 1
  sleep 0.5
  click_button 2
  wait $dialog_pid || true
  pid_a="$(cat $out/answer-rows-12)"
  echo "row click A -> $pid_a"
  case "$pid_a" in session\ *) ;; *) echo "FAIL: 'Trust forever' did not grant: $pid_a" >&2; exit 1;; esac

  start_dialog 12 $out/answer-rows-12b
  win_geom
  xdotool mousemove --sync $((WIN_X + WIN_W / 2)) $((WIN_Y + 160 + 4 * ${toString rowHeight})) click 1
  sleep 0.5
  click_button 2
  wait $dialog_pid || true
  pid_b="$(cat $out/answer-rows-12b)"
  echo "row click B -> $pid_b"
  if [ "$pid_a" = "$pid_b" ]; then
    echo "FAIL: mouse row selection had no effect ($pid_a)" >&2
    exit 1
  fi

  ###########################################################################
  echo "== case 3: keyboard cannot approve =="
  start_dialog 4 $out/answer-keyboard
  win_geom
  for key in Return KP_Enter space Tab Tab Return space Tab KP_Enter Return; do
    xdotool key --window "$win" --clearmodifiers "$key"
    sleep 0.15
  done
  sleep 1
  magick import -window "$win" $out/keyboard.png
  if ! kill -0 $dialog_pid 2>/dev/null; then
    echo "FAIL: keyboard activation closed the dialog" >&2
    cat $out/answer-keyboard >&2
    exit 1
  fi
  if [ -s $out/answer-keyboard ]; then
    echo "FAIL: keyboard produced an answer: $(cat $out/answer-keyboard)" >&2
    exit 1
  fi
  # ... but Escape still denies.
  xdotool key --window "$win" --clearmodifiers Escape
  wait $dialog_pid || true
  grep -qx deny $out/answer-keyboard \
    || { echo "FAIL: Escape did not deny: $(cat $out/answer-keyboard)" >&2; exit 1; }

  echo "all cases passed" | tee $out/result
''
