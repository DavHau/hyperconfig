# Paths, ports and the firewall chain of the agents, as plain functions of
# the agent's name. The core module derives everything from them, and a
# consumer that has to name an agent's port or unit without evaluating the
# host (a mullvad rule, a test, another machine) takes them from
# `hyperhermes.lib`, so the numbers live in one place.
#
# The names are what the running machine knows (unit names, directories,
# the iptables chain): changing one moves an agent's state or orphans a
# rule on a deployed host.
{ lib }:
rec {
  # Per agent a root 0711 directory, so the owner's units can traverse it,
  # holding the owner's 0700 state directory.
  stateRoot = "/var/lib/hermes";
  baseDir = user: "${stateRoot}/${user}";
  stateDir = user: "${baseDir user}/state";

  # The agent's directory in the owner's home, and its working directory.
  hermesDir = user: "/home/${user}/hermes";
  workspace = user: "${hermesDir user}/workspace";

  # The long-running system units that run as the agent's uid: core's
  # gateway and dashboard, and the browser feature's Camofox server.
  agentUnits = user: [
    "hermes-agent-${user}"
    "hermes-dashboard-${user}"
    "hermes-camofox-${user}"
  ];

  # iptables chain of the owner-only loopback gates (the core firewall).
  # Features append their own gates to it. The name predates this flake
  # and stays: it is the live chain on deployed hosts.
  chain = "hermes-native";

  # A u32 identity from the USERNAME, so the public port is known at eval
  # time without a pinned uid.
  identityHash = user: lib.fromHexString (builtins.substring 0 8 (builtins.hashString "sha256" user));

  # Root-held 127.0.0.1 port of a user's dashboard. Clients (nginx, the
  # owner) dial it; a per-connection owner-checking forward bridges it to
  # the backend below.
  dashboardPortFor = user: 22100 + lib.mod (identityHash user) 1000;

  # The dashboard backend the owner binds on loopback: base + uid. The
  # window sits below the kernel's ephemeral range for every normal uid,
  # so an outbound connection never squats a backend (the core options
  # assert it).
  dashboardBackendBase = 20000;

  # Lower bound of the kernel's ephemeral port range on a machine, from
  # its sysctl (the kernel default 32768 if unset). A backend port in that
  # range could be the source port of the bridge's own dial while the
  # backend is down: the kernel then connects the socket to itself
  # (simultaneous open), owned by the owner, and the bridge's owner check
  # passes. Every bridged backend window must stay below it (asserted for
  # each forward, and by every feature with a window of its own). An
  # assertion rather than ip_local_reserved_ports: out of the range, a
  # window needs no runtime state, and a uid that would push it in fails
  # the build instead of silently relying on a sysctl applied after boot.
  ephemeralPortLow =
    sysctl:
    let
      range = sysctl."net.ipv4.ip_local_port_range" or null;
    in
    if range == null then
      32768
    else
      lib.toInt (
        lib.head (
          lib.filter (s: s != "") (
            lib.splitString " " (builtins.replaceStrings [ "\t" ] [ " " ] (toString range))
          )
        )
      );

  # The browser feature's per-agent Camofox server, on the same scheme: a
  # root-held port per agent, bridged to a backend the owner binds at
  # base + uid. Both windows sit above the dashboard's.
  camofoxPortFor = user: 23100 + lib.mod (identityHash user) 1000;
  camofoxBackendBase = 24000;
  camofoxDir = user: "${stateDir user}/camofox";
}
