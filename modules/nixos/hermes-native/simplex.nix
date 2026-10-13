# SimpleX Chat control channel, as a unit factory: a simplex-chat daemon
# on loopback, driven by the hermes gateway's simplex plugin via
# SIMPLEX_WS_URL, plus the unit that publishes the profile address.
# native.nix calls it once per agent. Vendored from spaces 6d744780
# modules/nixos/hermes/simplex.nix.
#
# The daemon speaks a TCP websocket only (`--chat-server-port`), and the
# plugin dials a ws:// URL, so a unix socket is not an option. Every
# agent's daemon shares the host loopback, and a loopback port belongs
# to whoever binds it first. So the daemon binds nativeSimplexBase + uid,
# and clients dial `wsUrl`, a root-held socket unit that sockets.nix
# forwards through tcp-owner-bridge.rs. That bridge refuses a backend
# another uid bound.
{ lib, pkgs }:
{
  # Unit name suffix, "-<user>".
  suffix,
  package,
  user,
  group,
  # The URL clients dial. The address unit uses it too.
  wsUrl,
  displayName,
  stateDir,
  addressFile,
  # After= these units.
  after ? [ ],
}:
let
  hlib = import ./lib.nix { inherit lib; };
  addressTool = pkgs.writers.writePython3Bin "hermes-simplex-address" {
    libraries = [ pkgs.python3Packages.websockets ];
    # ruff format (treefmt) wraps at 88 columns; flake8's 79 would undo it.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./simplex-address.py);
  daemonArgs = lib.concatStringsSep " " [
    (lib.getExe package)
    # --database is a path prefix: the daemon appends _chat.db and _agent.db.
    "--database ${stateDir}/simplex_v1"
    "--files-folder ${stateDir}/files"
    # Same filesystem as the files folder. With the default (the
    # system temp directory) simplex-chat 7.0.0 stalls every XFTP
    # receive at 100% and leaves a zero-byte target file.
    "--temp-folder ${stateDir}/temp"
    "--user-display-name ${lib.escapeShellArg displayName}"
    "--yes-migrate"
  ];
  # The uid resolves at run time, so the port needs a shell.
  startScript = pkgs.writeShellScript "hermes-simplex-start" ''
    exec ${daemonArgs} --chat-server-port $((${toString hlib.nativeSimplexBase} + $(${pkgs.coreutils}/bin/id -u)))
  '';
in
{
  inherit addressTool wsUrl startScript;
  daemonUnit = "hermes-simplex${suffix}";

  # Root tmpfiles: the parent of stateDir is not user-writable, and a
  # foreign-owner leftover must be re-owned, not fatal.
  tmpfiles = [
    "d ${stateDir} 0700 ${user} ${group} - -"
    "d ${stateDir}/files 0700 ${user} ${group} - -"
    "d ${stateDir}/temp 0700 ${user} ${group} - -"
  ];

  services = {
    "hermes-simplex${suffix}" = {
      description = "SimpleX Chat daemon for the hermes gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ after;
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ stateDir ];
      serviceConfig = {
        User = user;
        Group = group;
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;
        # No prompts: a display-name or migration prompt leaves the unit dead.
        ExecStart = "${startScript}";
      };
    };

    # Separate unit, not ExecStartPost: the daemon's first answer waits on
    # its SMP relay, and that wait must not delay the agent.
    "hermes-simplex-address${suffix}" = {
      description = "Publish the SimpleX address of the hermes profile";
      wantedBy = [ "multi-user.target" ];
      after = [ "hermes-simplex${suffix}.service" ];
      requires = [ "hermes-simplex${suffix}.service" ];
      environment.SIMPLEX_WS_URL = wsUrl;
      unitConfig.RequiresMountsFor = [ (builtins.dirOf addressFile) ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Retry until the address is published.
        Restart = "on-failure";
        RestartSec = 30;
        User = user;
        Group = group;
        ExecStart = "${pkgs.writeShellScript "hermes-simplex-address-write" ''
          set -euo pipefail
          # Atomic write: keep the previous address on failure.
          tmp=${addressFile}.new
          ${lib.getExe addressTool} > "$tmp"
          test -s "$tmp"
          mv "$tmp" ${addressFile}
        ''}";
      };
    };
  };
}
