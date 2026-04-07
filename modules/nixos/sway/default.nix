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
  environment.etc."sway/config.d/custom.config".source = pkgs.writeText "sway-custom-config" (import ./sway.config.nix {inherit pkgs;});
  environment.etc."sway/config".source = ./sway-defaults.config;
}
