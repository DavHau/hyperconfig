# Root-held public loopback ports, their per-connection owner-checking
# forwards, and the state directories. Vendored from spaces 6d744780
# modules/nixos/hermes/host.nix (native subset).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib) baseDir;

  # Owner-uid check and splice for a user's public ports.
  # ./tcp-owner-bridge.rs explains why the check IS the access control.
  tcpOwnerBridgeBin = pkgs.writers.writeRustBin "hermes-tcp-owner-bridge" {
    rustcArgs = [
      "-O"
      "--edition"
      "2021"
    ];
  } ./tcp-owner-bridge.rs;

  # A per-connection forward to a user's backend. It runs as the owner:
  # the bridge derives the backend port from its own uid and refuses a
  # backend another uid bound. stderr goes to the journal, or
  # StandardInput=socket would leak the refusal to the dialer.
  ownerForward = user: base: what: {
    description = "${what} forward for native ${user}";
    serviceConfig = {
      User = user;
      ExecStart = "${tcpOwnerBridgeBin}/bin/hermes-tcp-owner-bridge ${toString base}";
      StandardInput = "socket";
      StandardError = "journal";
    };
  };

  # Static top-level option keys only (see native.nix).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.enabledUsers);
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = forEachUser (
      user: _: {
        "hermes-dashboard-fwd-${user}@" = ownerForward user hlib.nativeDashboardBase "dashboard";
        "hermes-simplex-fwd-${user}@" = lib.mkIf cfg.simplex.enable (
          ownerForward user hlib.nativeSimplexBase "simplex"
        );
      }
    );

    # Root binds the listeners at boot and never releases them, so no
    # squat window exists while an owner's daemon is down. iptables
    # owner-match (firewall.nix) gates the connects; the forward dials the
    # owner's backend through the uid check.
    systemd.sockets = forEachUser (
      user: ucfg: {
        "hermes-dashboard-fwd-${user}" = {
          description = "dashboard forward socket for ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString ucfg.dashboardPort}" ];
          socketConfig.Accept = true;
        };
        "hermes-simplex-fwd-${user}" = lib.mkIf cfg.simplex.enable {
          description = "simplex websocket forward socket for ${user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString ucfg.simplexPort}" ];
          socketConfig.Accept = true;
        };
      }
    );

    systemd.tmpfiles.rules = [
      "d /var/lib/hermes-microvm 0755 root root - -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: ucfg:
        [
          "d ${baseDir user} 0755 root root - -"
          # The vault is root-only; the owner's units open the state dir
          # inside it, so they need to traverse the vault: 0711.
          "d ${hlib.stateVault user} 0711 root root - -"
          "d ${hlib.stateVaultState user} 0700 ${user} users - -"
          "d ${hlib.exchangeDir user} 0755 ${user} users - -"
          "d ${hlib.workspace user} 0755 ${user} users - -"
        ]
        # The per-user gateway socket must exist at boot, before any
        # interactive login, so this lingers the owner. The file IS the
        # linger protocol (`loginctl enable-linger` creates it). Not
        # users.users.<u>.linger: the account belongs to the host config.
        # CAVEAT: users.manageLingering = true garbage-collects linger
        # files not declared via users.users.<u>.linger.
        ++ lib.optional ucfg.spacesGateway.enable "f /var/lib/systemd/linger/${user} 0644 root root - -"
      ) cfg.enabledUsers
    );
  };
}
