{pkgs, ...}: {
  programs.sway.enable = true;
  programs.sway.wrapperFeatures.gtk = true;
  nixpkgs.overlays =  [
    (self: super: {
      # make flameshot wayland compatible
      flameshot = super.flameshot.override  {
        enableWlrSupport = true;
        enableMonochromeIcon = true;
      };
    })
  ];
  # programs.sway.extraOptions = [ "--config" "${./config}" ];
  programs.sway.extraConfig = ''
    # include ${./sway-defaults.config}
    include ${pkgs.writeText "sway-config" (import ./sway.config.nix {inherit pkgs;})}
  '';
  environment.etc."sway/config".source = ./sway-defaults.config;
}
