# The hermes-desktop Electron app: OUR nixpkgs electron plus upstream's
# npm-built renderer, assembled by ./desktop.nix (vendored from upstream's
# nix/desktop.nix). Upstream's own `desktop` package is built with the
# electron of the hermes-agent package's pkgs; ours takes the caller's.
# hermesNpmLib, the install stamp and the agent package come from
# upstream's default-package passthru; the icons from upstream's
# nix/icons.nix, which renders them on the agent's venv (Pillow and
# resvg-py are core dependencies), as upstream's own package does.
#
# `hermes-agent` is this flake's input; `pkgs` is the caller's, so a
# system builds it against its own nixpkgs (nixosModules.desktop).
{ pkgs, hermes-agent }:
let
  # rev = null: upstream bakes HERMES_REVISION from `inputs.self.rev`
  # into the wrapper, and only for the "update available" banner. A
  # `path:` lock has no rev, so the wrapper would differ between a git
  # and a path checkout and drag the whole Electron renderer into a
  # rebuild. The node fix: ../hermes-agent-node.nix.
  hermesAgent =
    import ../hermes-agent-node.nix pkgs
      (hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
        rev = null;
      });
in
pkgs.callPackage ./desktop.nix {
  inherit (hermesAgent.passthru) hermesNpmLib installStampFile;
  generatedIcons = pkgs.callPackage "${hermes-agent}/nix/icons.nix" {
    venv = hermesAgent.passthru.hermesVenv;
  };
  inherit hermesAgent;
  # Upstream references these files as ../ siblings of nix/; hand
  # desktop.nix the flake source instead.
  hermesSrc = hermes-agent;
  inherit (pkgs) electron;
}
