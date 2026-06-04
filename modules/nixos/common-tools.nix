{
  pkgs,
  lib,
  ...
}: {
  environment.systemPackages = lib.attrValues {
    inherit (pkgs)
      bat
      file
      git
      htop
      python3
      screen
      tmux
      vim
      ;
  };

  # Mouse-wheel / touchpad two-finger scrolling in tmux. tmux sources
  # /etc/tmux.conf for every session; `mouse on` makes it capture scroll
  # events (enters copy-mode to page through scrollback).
  environment.etc."tmux.conf".text = ''
    set -g mouse on
  '';

  programs.direnv.enable = true;

  programs.bash.interactiveShellInit = ''
    if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
    then
      shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
      exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
    fi
  '';
}
