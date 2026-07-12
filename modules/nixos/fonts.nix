{pkgs, lib, ...}: {
  fonts.packages = [
    pkgs.nerd-fonts.fira-code
    pkgs.julia-mono
  ];

  # FiraCode has no braille glyphs (U+2800-U+28FF). Without an explicit
  # fallback, fontconfig resolves braille to FreeMono, which draws the
  # *empty* dot positions as hollow circles -> braille art/spinners render
  # as a grid of rings. JuliaMono leaves empty dots blank.
  fonts.fontconfig.localConf = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <alias>
        <family>FiraCode Nerd Font</family>
        <prefer>
          <family>JuliaMono</family>
        </prefer>
      </alias>
    </fontconfig>
  '';
}
