# Hermes launchers on a workstation for the agents of a hyperhermes host
# (`services.hyperhermes.desktop`): `hermes-desktop` (the Electron app,
# packages.hermes-desktop), plus a "Hermes Desktop" entry and one
# "Hermes TUI (<agent>)" entry per agent for app launchers. Independent of
# core: the agents run elsewhere, this machine only dials them.
#
# Desktop app: every agent is a `remote` connection to its always-on
# hosted dashboard, https://<agent>.<domain> (the dashboards module's
# public scheme), with OAuth: the dashboard advertises auth_required and
# its self-hosted provider, and the app signs in through it. The user signs
# in once per agent inside the app; the sessions live in the app's cookie
# partitions, so the managed entries can be rewritten freely.
# ./connections.py merges the entries into the app's files on every launch.
# Chats run in the dashboard unit on the agents' host, not in a process
# the app owns, so quitting the app leaves running sessions and subagents
# alone.
#
# TUI: a plain `ssh -t <agent>@<host> hermes` with the user's normal
# identities and a real pty, the host key trusted under `hostKeyAlias` if
# set.
#
# `hermes-agent` is this flake's input, the source of the app.
{ hermes-agent }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.desktop;

  icon = "${cfg.package}/share/hermes-desktop/dist/hermes.png";

  spec = pkgs.writeText "hermes-desktop-connections.json" (
    builtins.toJSON {
      inherit (cfg) primary;
      remotes = lib.mapAttrs (agent: label: {
        inherit label;
        url = "https://${agent}.${cfg.domain}";
      }) cfg.agents;
    }
  );

  # passthru.spec: what ./connections.py merges, for checks to inspect.
  hermesDesktop =
    (pkgs.writeShellScriptBin "hermes-desktop" ''
      ${pkgs.python3}/bin/python3 ${./connections.py} ${spec}
      exec ${cfg.package}/bin/hermes-desktop "$@"
    '').overrideAttrs
      { passthru = { inherit spec; }; };

  hostKeyArg = lib.optionalString (cfg.hostKeyAlias != null) "-o HostKeyAlias=${cfg.hostKeyAlias} ";

  tui =
    agent:
    pkgs.writeShellScriptBin "hermes-tui-${agent}" ''
      ${pkgs.openssh}/bin/ssh -t ${hostKeyArg}${agent}@${cfg.host} hermes "$@"
      rc=$?
      if [ "$rc" -ne 0 ]; then
        printf '\nhermes exited with status %d - press Enter to close\n' "$rc"
        read -r _
      fi
      exit "$rc"
    '';

  desktopItem = pkgs.makeDesktopItem {
    name = "hermes-desktop";
    desktopName = "Hermes Desktop";
    comment = "Hermes Agent desktop app (${cfg.hostLabel}'s agents)";
    exec = if cfg.desktopEntryExec != null then cfg.desktopEntryExec else "${hermesDesktop}/bin/hermes-desktop";
    inherit icon;
    categories = [
      "Network"
      "Chat"
    ];
  };

  tuiItem =
    agent:
    pkgs.makeDesktopItem {
      name = "hermes-tui-${agent}";
      desktopName = "Hermes TUI (${cfg.agents.${agent}})";
      comment = "Hermes Agent terminal UI on ${cfg.hostLabel}";
      exec = "${tui agent}/bin/hermes-tui-${agent}";
      inherit icon;
      terminal = true;
      categories = [
        "Network"
        "ConsoleOnly"
      ];
    };
in
{
  # Imported with its argument applied (../../flake.nix), so it names
  # its own file for error messages.
  _file = ./default.nix;

  options.services.hyperhermes.desktop = with lib; {
    enable = mkEnableOption "the hermes-desktop app and TUI launchers for a remote hyperhermes host's agents";
    package = mkOption {
      type = types.package;
      default = import ../../pkgs/hermes-desktop { inherit pkgs hermes-agent; };
      defaultText = literalMD "packages.hermes-desktop, built against this system's nixpkgs";
      description = "The Electron app the `hermes-desktop` launcher runs.";
    };
    host = mkOption {
      type = types.str;
      example = "hermes.example.org";
      description = "SSH host name of the machine the agents run on; the TUI entries dial it.";
    };
    hostLabel = mkOption {
      type = types.str;
      default = cfg.host;
      defaultText = literalExpression "config.services.hyperhermes.desktop.host";
      description = ''
        Short name of the agents' host, used in the launcher entries.
      '';
    };
    hostKeyAlias = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ssh HostKeyAlias under which the host key is already trusted
        (ssh_known_hosts, a @cert-authority line, ...), for the TUI.
      '';
    };
    domain = mkOption {
      type = types.str;
      example = "example.org";
      description = ''
        Domain of the agents' hosted dashboards: the app connects to
        `https://<agent>.<domain>` with OAuth.
      '';
    };
    agents = mkOption {
      type = types.attrsOf types.str;
      example = {
        alice = "Alice's agent";
      };
      description = "Agent account on the host -> label shown in the app and the TUI entry.";
    };
    primary = mkOption {
      type = types.str;
      description = "The agent (a key of `agents`) the first window opens on.";
    };
    desktopEntryExec = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Command line of the "Hermes Desktop" launcher entry, e.g. a wrapper
        that turns a failed start into a notification and runs
        `hermes-desktop` from PATH. null runs the launcher directly.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.agents ? ${cfg.primary};
        message = "services.hyperhermes.desktop.primary (${cfg.primary}) must be one of services.hyperhermes.desktop.agents.";
      }
    ];

    environment.systemPackages = [
      hermesDesktop
      desktopItem
    ]
    ++ map tuiItem (lib.attrNames cfg.agents);
  };
}
