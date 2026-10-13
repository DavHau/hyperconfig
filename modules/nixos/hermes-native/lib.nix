# Paths, ports and identities of native agents. Vendored from spaces
# 6d744780 modules/nixos/hermes/lib.nix (native subset). The paths and
# port formulas stay identical to spaces', so state written under the
# spaces module and clients that dial the hash-derived ports keep working.
{ lib }:
rec {
  # Kept under the spaces name: the vault predates this module.
  baseDir = user: "/var/lib/hermes-microvm/${user}";
  # The root-only vault, and the user-owned agent state inside it.
  stateVault = user: "${baseDir user}/state-vault";
  stateVaultState = user: "${stateVault user}/state";

  # The user's exchange dir and the agent's working directory.
  exchangeDir = user: "/home/${user}/hermes";
  workspace = user: "${exchangeDir user}/workspace";

  # The user's NixOS configuration repo.
  homeDir = user: "/home/${user}";
  configRepoDir = user: rel: "${homeDir user}/${rel}";

  # Whether an absolute host path lies INSIDE this user's home. A repo
  # under one user's home must never reach another user's agent, and the
  # home directory itself is never a repo.
  inHomeOf = user: path: lib.hasPrefix "${homeDir user}/" path;

  # Written by the simplex address unit, read by `hermes-simplex-qr`.
  simplexAddressFile = user: "${exchangeDir user}/simplex-address.txt";

  # The unit name of the user's microVM under the spaces module. Only
  # the one-runner guard (native.nix) names it.
  vmName = user: "hermes-${user}";

  # A u32 identity from the USERNAME, the stable eval-time key for the
  # public ports below. uids are runtime-allocated.
  identityHash = user: lib.fromHexString (builtins.substring 0 8 (builtins.hashString "sha256" user));

  # Root-held public 127.0.0.1 port of a user's dashboard. Remote
  # clients (spaces hermes-remote) compute the same formula, so it must
  # not drift from spaces' copy.
  dashboardPortFor = user: 22100 + lib.mod (identityHash user) 1000;

  # Root-held public loopback port of a user's simplex websocket. The
  # agent dials it. Its own window keeps it clear of the dashboard ports.
  simplexPortFor = user: 24100 + lib.mod (identityHash user) 1000;

  # Backend ports the owner's own daemons bind on the host loopback, as
  # base + uid. The root-held public ports above forward to them through
  # tcp-owner-bridge.rs, which refuses a backend another uid bound. Both
  # windows sit below the kernel's ephemeral range (32768+) for every
  # desktop uid, so an outbound connection never squats a backend.
  nativeSimplexBase = 10000;
  nativeDashboardBase = 20000;
}
