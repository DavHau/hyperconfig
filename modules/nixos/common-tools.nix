{
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    inputs.direnv-sandbox.nixosModules.default
  ];
  environment.systemPackages = lib.attrValues {
    inherit (pkgs)
      bat
      file
      git
      htop
      screen
      vim
      ;
  };

  programs.direnv.enable = true;
  programs.direnv.sandbox = {
    enable = true;
    allowParent = "read";
    persist = [
      "$HOME/.claude"
    ];
    bind = {
      "$HOME/.pi" = {};
      "$HOME/.local/share/zoxide" = {};
      "$HOME/.claude/.credentials.json" = {};
    };
    bindReadOnly = {
      "$HOME/.ssh/id_ed25519_github1".to = "$HOME/.ssh/id_ed25519";
      "$HOME/.ssh/id_ed25519_github1.pub".to = "$HOME/.ssh/id_ed25519.pub";
    };
  };

  programs.bash.interactiveShellInit = ''
    if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
    then
      shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
      exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
    fi
  '';
}
