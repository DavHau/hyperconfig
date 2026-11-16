# nixpkgs-bump-workspace (./workspace.sh), for ../nixpkgs-bump.nix (the
# guest's PATH) and ./workspace-test.nix. `repo` is fixed at build time
# (no flag): the test builds its own variant.
{
  pkgs,
  repo ? "/home/infra/hyperconfig",
  logDir ? "/home/infra/nixpkgs-bump",
  # create's liveness check (./workspace.sh is_live): an earlier night's
  # workspace changed this recently is a run still going
  liveMinutes ? 30,
  staleMinutes ? 20 * 60,
  # the run's liveness stamp (<logDir>/<name>.alive, refreshed at each
  # step): younger than this, the earlier run is alive
  aliveMinutes ? 120,
  # archive bookmarks (nixpkgs-bump-archive/*) older than this are pruned
  archiveDays ? 14,
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
      [ "@repo@" "@logDir@" "@jjConfig@" "@path@" "@liveMinutes@" "@staleMinutes@" "@aliveMinutes@" "@archiveDays@" ]
      [
        repo
        logDir
        "${jjConfig}"
        path
        (toString liveMinutes)
        (toString staleMinutes)
        (toString aliveMinutes)
        (toString archiveDays)
      ]
      (builtins.readFile ./workspace.sh);
}
