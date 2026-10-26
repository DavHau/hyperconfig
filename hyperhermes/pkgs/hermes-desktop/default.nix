# The hermes-desktop Electron app: OUR nixpkgs electron plus upstream's
# npm-built renderer, assembled by ./desktop.nix (copied from spaces'
# modules/nixos/hermes/desktop-package.nix, spaces-os rev 6d744780).
# Upstream's own `desktop` package pins a node-headers hash for THEIR
# nixpkgs' electron. It breaks under nixpkgs follows. Ours takes the
# headers from `electron.headers`, version-locked by construction.
# hermesNpmLib and the agent package come from upstream's default-package
# passthru.
#
# `hermes-agent` is this flake's input; `pkgs` is the caller's, so a
# system builds it against its own nixpkgs (nixosModules.desktop).
{ pkgs, hermes-agent }:
let
  # rev = null: upstream bakes HERMES_REVISION from `inputs.self.rev`
  # into the wrapper, and only for the "update available" banner. A
  # `path:` lock has no rev, so the wrapper would differ between a git
  # and a path checkout and drag the whole Electron renderer into a
  # rebuild.
  hermesAgent = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    rev = null;
  };
in
pkgs.callPackage ./desktop.nix {
  inherit (hermesAgent.passthru) hermesNpmLib;
  inherit hermesAgent;
  # Upstream references these files as ../ siblings of nix/; hand
  # desktop.nix the flake source instead.
  hermesSrc = hermes-agent;
  inherit (pkgs) electron;
}
