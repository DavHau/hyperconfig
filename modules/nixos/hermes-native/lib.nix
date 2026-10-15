# Paths, ports and the firewall chain of the native agents. Consumers
# outside this directory import it too, so the numbers live in one place.
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

  # The long-running system units that run as the agent's uid
  # (agents.nix, camofox.nix).
  agentUnits = user: [
    "hermes-agent-${user}"
    "hermes-dashboard-${user}"
    "hermes-camofox-${user}"
  ];

  # iptables chain of the owner-only loopback gates (firewall.nix).
  # Consumers append their own gates to it.
  chain = "hermes-native";

  # A u32 identity from the USERNAME, so the public port is known at eval
  # time without a pinned uid.
  identityHash = user: lib.fromHexString (builtins.substring 0 8 (builtins.hashString "sha256" user));

  # Root-held 127.0.0.1 port of a user's dashboard. Clients (nginx, the
  # owner) dial it; a per-connection owner-checking forward bridges it to
  # the backend below.
  dashboardPortFor = user: 22100 + lib.mod (identityHash user) 1000;

  # The dashboard backend the owner binds on loopback: base + uid. The
  # window sits below the kernel's ephemeral range (32768+) for every
  # normal uid, so an outbound connection never squats a backend.
  dashboardBackendBase = 20000;

  # The agent's Camofox browser server (camofox.nix), on the same scheme:
  # a root-held port per agent, bridged to a backend the owner binds at
  # base + uid. Both windows sit above the dashboard's.
  camofoxPortFor = user: 23100 + lib.mod (identityHash user) 1000;
  camofoxBackendBase = 24000;
  camofoxDir = user: "${stateDir user}/camofox";

  # Every root-held port and its owner-bound backend (forwards.nix,
  # firewall.nix).
  forwards = {
    dashboard = {
      label = "Dashboard";
      portFor = dashboardPortFor;
      backendBase = dashboardBackendBase;
    };
    camofox = {
      label = "Camofox";
      portFor = camofoxPortFor;
      backendBase = camofoxBackendBase;
    };
  };
}
