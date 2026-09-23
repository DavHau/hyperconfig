{pkgs, ...}: {
  fonts.packages = [ pkgs.nerd-fonts.fira-code ];

  # The generic monospace font must cover Braille (U+2800-U+28FF: logos,
  # spinners, plots). NixOS' default, DejaVu Sans Mono, does not, and the
  # next monospace fallback fontconfig knows (40-nonlatin.conf) is FreeMono
  # from the default font set, which draws the *unset* dot positions as
  # hollow rings - braille art turns into a grid of circles in browsers
  # and terminals alike. FiraCode Nerd Font has the block and draws it
  # right; naming it here makes it the first choice for `monospace`.
  fonts.fontconfig.defaultFonts.monospace = [ "FiraCode Nerd Font" ];
}
