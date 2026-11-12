# Ghostty's terminfo (xterm-ghostty) on every machine and in the spaces'
# guests, so an ssh session from Dave's ghostty (./ghostty.nix) keeps
# backspace, colours and the alternate screen on the far side.
#
# Taken from the main nixpkgs for the build platform: the terminfo is
# architecture-independent, so it is the binary cache's copy everywhere,
# including the cross-built cm-pi (whose own package set would build
# ghostty from source just for this file).
{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    inputs.nixpkgs.legacyPackages.${pkgs.stdenv.buildPlatform.system}.ghostty.terminfo
  ];
}
