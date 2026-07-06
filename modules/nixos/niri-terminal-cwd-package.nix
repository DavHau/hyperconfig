# Terminal launcher for niri's Mod+T: open alacritty in the working directory
# of the focused window's process instead of always $HOME.
#
# `niri` and `alacritty` are resolved from the session PATH by bare name (the
# same convention the spaces command wrappers use), which keeps this script's
# closure small and lets tests stub both.
{ pkgs }:
pkgs.writeShellApplication {
  name = "niri-terminal-cwd";
  runtimeInputs = [
    pkgs.jq
    pkgs.procps # pgrep
  ];
  text = ''
    # Focused window's process; empty when nothing is focused or niri is
    # unreachable.
    pid=$(niri msg --json focused-window | jq -r '.pid // empty') || pid=""

    cwd=""
    if [ -n "$pid" ]; then
      # A terminal window's pid is the emulator, not the shell running in it.
      # Walk down to the newest descendant (terminal -> shell -> foreground
      # program) and use that process's cwd. Windows without children (plain
      # GUI apps) keep their own pid.
      while child=$(pgrep -n -P "$pid"); do
        pid=$child
      done
      cwd=$(readlink -e "/proc/$pid/cwd") || cwd=""
    fi

    # Only trust directories inside $HOME; anything else (daemons rooted at /,
    # unreadable /proc of other users' processes, vanished dirs) opens at
    # $HOME.
    case $cwd in
      "$HOME" | "$HOME"/*) ;;
      *) cwd=$HOME ;;
    esac

    exec alacritty --working-directory "$cwd"
  '';
}
