# Hermes launchers on a workstation for the agents of a hyperhermes host
# (`services.hyperhermes.desktop`): `hermes-desktop` (the Electron app,
# packages.hermes-desktop), plus a "Hermes Desktop" entry and one
# "Hermes TUI (<agent>)" entry per agent for app launchers. Independent of
# core: the agents run elsewhere, this machine only dials them.
#
# Desktop app: every agent is an `ssh` connection, reached as
# <agent>@<host>. The SSH connection kind needs no token: the app runs
# `hermes serve --isolated` as the agent over ssh, tunnels the ephemeral
# port and adopts the token the remote mints. On the agents' host the
# command lands in the `hermes` shim of core, which exports the account's
# real HERMES_HOME, so it serves the same state the gateway and dashboard
# use. The managed dashboard.public_url does not gate it: hermes exempts
# the loopback backend the desktop spawns (HERMES_DESKTOP=1 plus its
# session token). ./connections.py merges the entries into the app's files
# on every launch.
#
# Identity: one passphrase-less ed25519 key (sshKeyFile, root-only; the
# clan module makes it the shared var hermes-desktop-ssh), never an admin
# key. Activation copies it to /run/hermes-desktop-ssh/<user>, owner-only,
# for each of `users`. Per-uid owners, not a shared group: a group added at
# deploy time is missing from every session that was already running. The
# agents' host should authorize the public half with `restrict` +
# loopback port-forwarding only: exactly the app's bootstrap
# (`-L 127.0.0.1:*:127.0.0.1:<port>`); no pty, so the desktop's
# remote-terminal tab is deliberately not served.
#
# The app drives the system `ssh` with BatchMode and an `-i` at most, never
# IdentitiesOnly, so with the default config every connect would first offer
# every agent identity (an ssh-agent prompting per use would prompt). So
# the app dials an alias whose Host block pins the restricted key; ssh
# resolves it to `host`. BatchMode cannot answer a TOFU prompt, so the host
# key must already be trusted, under `hostKeyAlias` if set.
#
# TUI: a plain `ssh -t <agent>@<host> hermes` with the user's normal
# identities and a real pty.
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
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);

  # What the app dials; only ssh_config below knows it.
  alias = "hermes-desktop-${cfg.hostLabel}";
  keyDir = "/run/hermes-desktop-ssh";

  icon = "${cfg.package}/share/hermes-desktop/dist/hermes.png";

  spec = pkgs.writeText "hermes-desktop-connections.json" (
    builtins.toJSON {
      inherit (cfg) primary;
      remotes = lib.mapAttrs (user: label: {
        inherit label user;
        host = alias;
      }) cfg.agents;
    }
  );

  hermesDesktop = pkgs.writeShellScriptBin "hermes-desktop" ''
    ${pkgs.python3}/bin/python3 ${./connections.py} ${spec}
    exec ${cfg.package}/bin/hermes-desktop "$@"
  '';

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
      description = "SSH host name of the machine the agents run on.";
    };
    hostLabel = mkOption {
      type = types.str;
      default = cfg.host;
      defaultText = literalExpression "config.services.hyperhermes.desktop.host";
      description = ''
        Short name of the agents' host: the ssh alias the app dials is
        `hermes-desktop-<hostLabel>`, and the launcher entries name it.
      '';
    };
    hostKeyAlias = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ssh HostKeyAlias under which the host key is already trusted
        (ssh_known_hosts, a @cert-authority line, ...). The app connects
        in BatchMode and cannot accept an unknown host key.
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
    users = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Local accounts that get an owner-only copy of the key and may launch the app.";
    };
    sshKeyFile = mkOption {
      type = types.str;
      description = ''
        Runtime path (outside the Nix store) of the passphrase-less ssh
        private key the app dials the agents with. The clan module fills it
        from the shared var hermes-desktop-ssh.
      '';
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
      {
        assertion = !inStore cfg.sshKeyFile;
        message = "services.hyperhermes.desktop.sshKeyFile must be a runtime path outside the Nix store; the store is world-readable.";
      }
    ];

    # /run is tmpfs and a secret store may rewrite the key on every
    # activation (clan's setupSecrets, boot included), so the copies are
    # refreshed right after it.
    system.activationScripts.hermes-desktop-ssh =
      lib.stringAfter (lib.optional (config.system.activationScripts ? setupSecrets) "setupSecrets")
        ''
          rm -rf ${keyDir}
          install -d -m 0755 -o root -g root ${keyDir}
          ${lib.concatMapStrings (u: ''
            install -m 0400 -o ${u} -g root ${cfg.sshKeyFile} ${keyDir}/${u}
          '') cfg.users}
        '';

    programs.ssh.extraConfig = ''
      Host ${alias}
        HostName ${cfg.host}
        IdentityFile ${keyDir}/%u
        IdentitiesOnly yes
        IdentityAgent none
    ''
    + lib.optionalString (cfg.hostKeyAlias != null) "  HostKeyAlias ${cfg.hostKeyAlias}\n";

    environment.systemPackages = [
      hermesDesktop
      desktopItem
    ]
    ++ map tuiItem (lib.attrNames cfg.agents);
  };
}
