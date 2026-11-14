# nixpkgs-bump-searxng-diff (./searxng-diff.sh): the review's diff of two
# SearXNG source trees, for ./searxng.nix and ./guard-test.nix.
{
  pkgs,
  # The python env of the hermes the reviewer runs (the infra-space
  # guest's services.hyperhermes.package.hermesVenv, passed in by
  # ../nixpkgs-bump.nix; flake.nix passes the same one to the guard
  # test): ./searxng-readcheck.py reads every part through ITS read_file,
  # so a hermes update that changes what read_file shows is checked by
  # the very next run, never by a copy of its rules here.
  hermesVenv,
  # one part of the review file: one read of the reviewer's file tool
  # (~100 K characters, line-number prefixes counted; 2000 lines a page)
  partBytes ? 90000,
  partLines ? 1800,
  # its longest line: that tool cuts a line over ~2000 characters
  # (`... [truncated]`), so longer ones are folded into pieces of at most
  # this many bytes (so no more characters), between UTF-8 characters
  lineChars ? 1900,
  # the uncounted (generated) files' diff, shown after the code, cut here
  genBytes ? 200000,
}:
let
  # ./searxng-text.py with Unicode's Default_Ignorable_Code_Point and
  # XID_Continue tables and its Scripts.txt (nixpkgs' UCD, one package,
  # not a hand list), and the public suffix list for registrable domains
  ucd = "${pkgs.unicode-character-database}/share/unicode";
  textPy = pkgs.writeText "searxng-text.py" (
    builtins.replaceStrings [ "@ucdDerived@" "@ucdScripts@" "@publicSuffixList@" ] [
      "${ucd}/DerivedCoreProperties.txt"
      "${ucd}/Scripts.txt"
      "${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat"
    ] (builtins.readFile ./searxng-text.py)
  );
in
pkgs.writeShellApplication {
  name = "nixpkgs-bump-searxng-diff";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.git
  ];
  text =
    builtins.replaceStrings
      [ "@partBytes@" "@partLines@" "@genBytes@" "@lineChars@" "@hermesPython@" "@readcheck@" "@python@" "@text@" ]
      [
        (toString partBytes)
        (toString partLines)
        (toString genBytes)
        (toString lineChars)
        "${hermesVenv}/bin/python3"
        "${./searxng-readcheck.py}"
        "${pkgs.python3}/bin/python3"
        "${textPy}"
      ]
      (builtins.readFile ./searxng-diff.sh);
}
