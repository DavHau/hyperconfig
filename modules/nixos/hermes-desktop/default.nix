# Hermes launchers on the dave desktops for som's native agents
# (machines/som/hermes-agents.nix): `hermes-desktop` (the Electron app,
# also what the niri keybind and the bar button spawn via spaces-hermes),
# plus a "Hermes Desktop" entry and one "Hermes TUI (<agent>)" entry per
# agent for app launchers. No local agent: amy's microVM is retired and
# spaces' launcher (hermes/cli.nix) only exists next to one.
#
# Desktop app: every agent below is an `ssh` connection, reached as
# <agent>@hermes.davhau.com (som's public name). The SSH connection kind
# needs no token: the app runs `hermes serve --isolated` as the agent over
# ssh, tunnels the ephemeral port and adopts the token the remote mints. On
# som the command lands in the `hermes` shim of hyperhermes' core, which
# exports the account's real HERMES_HOME, so it serves the same state the
# gateway and dashboard use. The managed dashboard.public_url does not gate
# it: hermes exempts the loopback backend the desktop spawns
# (HERMES_DESKTOP=1 plus its session token). ./connections.py merges the
# entries into the app's files on every launch.
#
# Identity: one passphrase-less ed25519 key for the fleet (shared clan var
# below), never the admin key. The var itself stays root 0400; activation
# copies it to /run/hermes-desktop-ssh/<user>, owner-only, for dave plus
# grmpf where that account exists (amy). Per-uid owners, not a shared
# group: a group added at deploy time is missing from every session that
# was already running. The public half lands on each agent account on som
# with `restrict` + loopback port-forwarding only: exactly the app's
# bootstrap (`-L 127.0.0.1:*:127.0.0.1:<port>`); no pty, so the desktop's
# remote-terminal tab is deliberately not served.
#
# The app drives the system `ssh` with BatchMode and an `-i` at most, never
# IdentitiesOnly, so with the default config every connect would first offer
# every agent identity - i.e. poke the TPM agent for a confirmation. So the
# app dials the alias below, whose Host block pins the restricted key; ssh
# resolves it to hermes.davhau.com. BatchMode cannot answer a TOFU prompt, so
# the host is verified as `som.d`: som presents its clan sshd CA certificate
# (principal som.d) on every address, and the sshd client role trusts that
# CA for `*.d` in ssh_known_hosts.
#
# TUI: a plain `ssh -t <agent>@hermes.davhau.com hermes` with the user's
# normal identities (the agent accounts take the admin keys) and a real pty.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  host = "hermes.davhau.com";
  # What the app dials; only ssh_config below knows it.
  alias = "hermes-desktop-som";
  # Agent account on som -> label; the first window opens on `primary`.
  agents = {
    dave-hermes = "dave-hermes";
    joe = "joe";
  };
  primary = "dave-hermes";

  key = config.clan.core.vars.generators.hermes-desktop-ssh.files.key.path;
  keyDir = "/run/hermes-desktop-ssh";
  users = [ "dave" ] ++ lib.optional (config.users.users ? grmpf) "grmpf";

  # Electron app: our nixpkgs electron plus upstream's renderer, assembled
  # by spaces' desktop-package.nix against hyperhermes' hermes-agent, the
  # one som's agents run.
  desktopPackage = import (inputs.spaces + /modules/nixos/hermes/desktop-package.nix) {
    inputs = { inherit (inputs.hyperhermes.inputs) hermes-agent; };
    inherit pkgs;
  };
  icon = "${desktopPackage}/share/hermes-desktop/dist/hermes.png";

  spec = pkgs.writeText "hermes-desktop-connections.json" (
    builtins.toJSON {
      inherit primary;
      remotes = lib.mapAttrs (user: label: {
        inherit label user;
        host = alias;
      }) agents;
    }
  );

  hermesDesktop = pkgs.writeShellScriptBin "hermes-desktop" ''
    ${pkgs.python3}/bin/python3 ${./connections.py} ${spec}
    exec ${desktopPackage}/bin/hermes-desktop "$@"
  '';

  tui =
    agent:
    pkgs.writeShellScriptBin "hermes-tui-${agent}" ''
      ${pkgs.openssh}/bin/ssh -t -o HostKeyAlias=som.d ${agent}@${host} hermes "$@"
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
    comment = "Hermes Agent desktop app (som's agents)";
    # spaces-hermes runs `hermes-desktop` and turns a failure into a
    # desktop notification, as the keybind and the bar button do.
    exec = "${config.services.spaces.commands.hermes}/bin/spaces-hermes";
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
      desktopName = "Hermes TUI (${agents.${agent}})";
      comment = "Hermes Agent terminal UI on som";
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
  clan.core.vars.generators.hermes-desktop-ssh = {
    share = true;
    files.key = { };
    files."key.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C hermes-desktop -f "$out"/key
    '';
  };

  # /run is tmpfs and setupSecrets rewrites the var on every activation
  # (boot included), so the copies are refreshed right after it.
  system.activationScripts.hermes-desktop-ssh = lib.stringAfter [ "setupSecrets" ] ''
    rm -rf ${keyDir}
    install -d -m 0755 -o root -g root ${keyDir}
    ${lib.concatMapStrings (u: ''
      install -m 0400 -o ${u} -g root ${key} ${keyDir}/${u}
    '') users}
  '';

  programs.ssh.extraConfig = ''
    Host ${alias}
      HostName ${host}
      IdentityFile ${keyDir}/%u
      IdentitiesOnly yes
      IdentityAgent none
      HostKeyAlias som.d
  '';

  environment.systemPackages = [
    hermesDesktop
    desktopItem
  ]
  ++ map tuiItem (lib.attrNames agents);
}
