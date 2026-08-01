# The ssh-tpm-agent confirmation dialog (see ssh-tpm-confirm-dialog.py).
#
# Factored out of ssh-tpm-agent.nix so the NixOS module, the VM test and the
# `ssh-tpm-confirm-dialog-preview` screenshot harness all run the exact same
# binary.
{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
in
pkgs.stdenvNoCC.mkDerivation {
  name = "ssh-tpm-confirm-dialog";
  src = ./ssh-tpm-confirm-dialog.py;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.wrapGAppsHook3 pkgs.gobject-introspection ];
  buildInputs = [ pkgs.gtk3 python ];
  installPhase = ''
    install -Dm755 $src $out/bin/ssh-tpm-confirm-dialog
    substituteInPlace $out/bin/ssh-tpm-confirm-dialog \
      --replace-fail '#!/usr/bin/env python3' '#!${python}/bin/python3'
  '';
}
