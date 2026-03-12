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
  programs.direnv.sandbox.enable = true;
  programs.direnv.sandbox.allowParent = "read";
  programs.direnv.sandbox.bind = [
    "$HOME/.pi"
    "$HOME/.local/share/zoxide"
  ];

  programs.bash.interactiveShellInit = ''
    if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
    then
      shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
      exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
    fi
  '';
}
