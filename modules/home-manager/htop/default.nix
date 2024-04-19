{
  programs.htop = {
    enable = true;
  };
  xdg.configFile."htop".recursive = true;
  xdg.configFile."htop".source = ./conf;
}

