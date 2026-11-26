# Messages from another agent into an agent's chat session: root's
# `hermes-notify <agent> [--profile P] [--session ID|--latest]
# [--from NAME] [MESSAGE]` (./agent-notify-cli.py), for every agent and
# every profile.
#
#   - patches/hermes-agent-notify.patch: the dashboard (which runs the
#     desktop and web chat sessions) listens on
#     /run/hermes-notify/<agent>/notify.sock, in the unit's own runtime
#     directory (0700, the agent's), and serves uid 0 only (SO_PEERCRED).
#     A running turn gets the message as a steer, like the owner's own
#     mid-turn messages; an idle session (reopened if needed) starts a turn
#     with it. The text is framed as a message from another agent, never
#     inside the owner's steer marker, and the system prompt says such a
#     message carries none of the owner's authority.
#   - the CLI checks the socket's server is the main process of
#     hermes-dashboard-<agent> (SO_PEERCRED pid against systemd's MainPID)
#     before it sends anything, so a stray listener of the agent's uid gets
#     nothing; no token or credential is involved.
#   - audit: one journal line per call (`journalctl -t hermes-notify`):
#     agent, profile, session, sender, message length, delivery; never the
#     text. The dashboard's agent.log has the same without the text.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  socketOf = user: "/run/hermes-notify/${user}/notify.sock";
  targets = pkgs.writeText "hermes-notify-agents.json" (
    builtins.toJSON (
      lib.mapAttrs (user: _: {
        socket = socketOf user;
        unit = "hermes-dashboard-${user}.service";
      }) cfg.agents
    )
  );
  cli = pkgs.writeShellScriptBin "hermes-notify" ''
    if [ "$(${pkgs.coreutils}/bin/id -u)" != 0 ]; then
      echo "hermes-notify: root only" >&2
      exit 77
    fi
    export HERMES_NOTIFY_AGENTS=${targets}
    export HERMES_NOTIFY_SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    exec ${pkgs.python3}/bin/python3 ${./agent-notify-cli.py} "$@"
  '';
in
{
  config = lib.mkIf (cfg.agents != { }) {
    environment.systemPackages = [ cli ];
    systemd.services = lib.mapAttrs' (
      user: _:
      lib.nameValuePair "hermes-dashboard-${user}" {
        environment.HERMES_AGENT_NOTIFY_SOCKET = socketOf user;
        serviceConfig = {
          RuntimeDirectory = "hermes-notify/${user}";
          RuntimeDirectoryMode = "0700";
        };
      }
    ) cfg.agents;
  };
}
