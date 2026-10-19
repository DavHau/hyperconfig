# The root-held ports of every agent (hlib.forwards: the dashboard, the
# Camofox browser server) and their per-connection owner-checking
# forwards to the owner's backends.
#
# A loopback port belongs to whoever binds it first, and netfilter gates
# connect(2), never bind(2). While an owner's backend is down, another
# uid could bind its port and receive whatever a client sends there. So
# clients (nginx, the owner) never dial a backend: they dial a port root
# holds for the whole uptime, and the forward refuses a backend another
# uid bound (tcp-owner-bridge.rs).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };

  tcpOwnerBridgeBin = import ./tcp-owner-bridge.nix { inherit pkgs; };

  # Static top-level option keys only (see agents.nix).
  forEachForward =
    f: lib.mkMerge (lib.concatLists (lib.mapAttrsToList (user: _: lib.mapAttrsToList (f user) hlib.forwards) cfg.users));
in
{
  config = lib.mkIf cfg.enable {
    # Runs as the owner: the bridge derives the backend port from its own
    # uid. stderr goes to the journal, or StandardInput=socket would leak
    # a refusal to the dialer.
    systemd.services = forEachForward (
      user: name: fwd: {
        "hermes-${name}-fwd-${user}@" = {
          description = "${fwd.label} forward for ${user}";
          serviceConfig = {
            User = user;
            ExecStart = "${tcpOwnerBridgeBin}/bin/hermes-tcp-owner-bridge ${toString fwd.backendBase}";
            StandardInput = "socket";
            StandardError = "journal";
          };
        };
      }
    );

    # The iptables owner-match gates (firewall.nix) decide who may dial.
    #
    # nginx opens one connection per request (no upstream keepalive), so
    # every request to a dashboard is one activation here, and anyone on
    # the internet can send those. The trigger limit (default 200
    # activations per 2s) would put the socket into the failed state for
    # good on a burst; TriggerLimitIntervalSec=0 disables it (systemd.socket(5)).
    # The poll limit (default 150 polling events per 2s) stays: it only
    # slows a flood down, and nginx's per-client-network limits
    # (../hermes-dashboard-public.nix) keep one client from taking it all.
    #
    # MaxConnections bounds the bridges running at once (one process
    # each); above it systemd refuses new connections (502) until one
    # ends, the socket keeps listening. A dashboard tab holds a handful of
    # long-lived websockets and streams; nginx allows one client network
    # at most 128 requests in flight per host, so 512 leaves room for
    # three more such clients at the limit, while still bounding what a
    # flood spread over many networks can spawn.
    systemd.sockets = forEachForward (
      user: name: fwd: {
        "hermes-${name}-fwd-${user}" = {
          description = "${fwd.label} forward socket for ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString (fwd.portFor user)}" ];
          socketConfig = {
            Accept = true;
            TriggerLimitIntervalSec = 0;
            MaxConnections = 512;
          };
        };
      }
    );
  };
}
