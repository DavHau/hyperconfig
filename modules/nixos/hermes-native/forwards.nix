# The root-held dashboard port of every agent and its per-connection
# owner-checking forward to the owner's backend.
#
# A loopback port belongs to whoever binds it first, and netfilter gates
# connect(2), never bind(2). While an owner's dashboard is down, another
# uid could bind its backend port and receive whatever a client sends
# there. So clients (nginx, the owner) never dial the backend: they dial
# a port root holds for the whole uptime, and the forward refuses a
# backend another uid bound (tcp-owner-bridge.rs).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };

  # ./tcp-owner-bridge.rs explains why the check IS the access control.
  tcpOwnerBridgeBin = pkgs.writers.writeRustBin "hermes-tcp-owner-bridge" {
    rustcArgs = [
      "-O"
      "--edition"
      "2021"
    ];
  } ./tcp-owner-bridge.rs;

  # Static top-level option keys only (see agents.nix).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.users);
in
{
  config = lib.mkIf cfg.enable {
    # Runs as the owner: the bridge derives the backend port from its own
    # uid. stderr goes to the journal, or StandardInput=socket would leak
    # a refusal to the dialer.
    systemd.services = forEachUser (
      user: _: {
        "hermes-dashboard-fwd-${user}@" = {
          description = "Dashboard forward for ${user}";
          serviceConfig = {
            User = user;
            ExecStart = "${tcpOwnerBridgeBin}/bin/hermes-tcp-owner-bridge ${toString hlib.dashboardBackendBase}";
            StandardInput = "socket";
            StandardError = "journal";
          };
        };
      }
    );

    # The iptables owner-match gates (firewall.nix) decide who may dial.
    systemd.sockets = forEachUser (
      user: _: {
        "hermes-dashboard-fwd-${user}" = {
          description = "Dashboard forward socket for ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString (hlib.dashboardPortFor user)}" ];
          socketConfig.Accept = true;
        };
      }
    );
  };
}
