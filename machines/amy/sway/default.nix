{...}: {
  programs.sway.enable = true;
  programs.sway.wrapperFeatures.gtk = true;
  programs.sway.extraOptions = [ "--config ${./config}" ];
}
