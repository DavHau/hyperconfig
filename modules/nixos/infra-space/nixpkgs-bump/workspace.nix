# nixpkgs-bump-workspace (./workspace.sh), for ../nixpkgs-bump.nix (the
# guest's PATH) and ./workspace-test.nix. `repo` is fixed at build time
# (no flag): the test builds its own variant.
{
  pkgs,
  repo ? "/home/infra/hyperconfig",
  logDir ? "/home/infra/nixpkgs-bump",
}:
let
  # The only jj config the helper's jj calls see (JJ_CONFIG, with an
  # empty HOME): no aliases, every file tracked on snapshot.
  jjConfig = (pkgs.formats.toml { }).generate "nixpkgs-bump-workspace-jj.toml" {
    ui.paginate = "never";
    snapshot = {
      auto-track = "all()";
      max-new-file-size = "1TiB";
    };
  };
  # The pinned PATH of the helper's jj and git calls (ssh for git's
  # fetch; it reads /etc/ssh/ssh_config and ssh_known_hosts).
  path = pkgs.lib.makeBinPath [
    pkgs.coreutils
    pkgs.git
    pkgs.jujutsu
    pkgs.openssh
  ];
in
pkgs.writeShellApplication {
  name = "nixpkgs-bump-workspace";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jujutsu
  ];
  text =
    builtins.replaceStrings
      [ "@repo@" "@logDir@" "@jjConfig@" "@path@" ]
      [ repo logDir "${jjConfig}" path ]
      (builtins.readFile ./workspace.sh);
}
