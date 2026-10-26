# The root-held ports of every agent (services.hyperhermes.forwards: the
# dashboard, and what features add) and their per-connection
# owner-checking forwards to the owner's backends.
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
  ...
}:
let
  cfg = config.services.hyperhermes;

  # Static top-level option keys only (see agents.nix).
  forEachForward =
    f:
    lib.mkMerge (
      lib.concatLists (lib.mapAttrsToList (user: _: lib.mapAttrsToList (f user) cfg.forwards) cfg.agents)
    );
in
{
  config = lib.mkIf (cfg.agents != { }) {
    # Runs as the owner: the bridge derives the backend port from its own
    # uid. stderr goes to the journal, or StandardInput=socket would leak
    # a refusal to the dialer. One instance per connection; a refusal (no
    # backend, or another uid's) exits non-zero, and CollectMode unloads
    # that failed instance instead of keeping it in `systemctl --failed`.
    # The refusal stays in the journal.
    systemd.services = forEachForward (
      user: name: fwd: {
        "hermes-${name}-fwd-${user}@" = {
          description = "${fwd.label} forward for ${user}";
          serviceConfig = {
            User = user;
            ExecStart = "${cfg.tcpOwnerBridge}/bin/hermes-tcp-owner-bridge ${toString fwd.backendBase}";
            StandardInput = "socket";
            StandardError = "journal";
          };
          unitConfig.CollectMode = "inactive-or-failed";
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
    # The poll limit (default for Accept=yes: 150 polling events per 2s,
    # each accepted connection one) pauses accepting for the rest of the
    # window, for every client. nginx lets one client network burst 500
    # requests at once and then 50 a second per host
    # (the public dashboards), so two clients at their limit
    # would pause the socket for everyone. PollLimitBurst=2000 per 2s
    # (1000 a second) holds the bursts of three client networks plus their
    # steady rate; only a flood spread over many networks hits it, and then
    # it only slows down (systemd.socket(5)).
    #
    # MaxConnections bounds the bridges running at once (one process
    # each); above it systemd refuses new connections (502) until one
    # ends, the socket keeps listening. A dashboard tab holds a handful of
    # long-lived websockets and streams; nginx allows one client network
    # at most 128 requests in flight per host, and all of them together
    # 384 (the public dashboards), so nginx never holds every
    # slot: 128 stay for the owner's own dialers, while the cap still
    # bounds what a flood spread over many networks can spawn.
    systemd.sockets = forEachForward (
      user: name: fwd: {
        "hermes-${name}-fwd-${user}" = {
          description = "${fwd.label} forward socket for ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString (fwd.portFor user)}" ];
          socketConfig = {
            Accept = true;
            TriggerLimitIntervalSec = 0;
            PollLimitIntervalSec = "2s";
            PollLimitBurst = 2000;
            MaxConnections = 512;
          };
        };
      }
    );
  };
}
