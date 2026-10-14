{
  programs.htop = {
    enable = true;
  };
  xdg.configFile."htop/htoprc".source = ./conf/htoprc;
}

