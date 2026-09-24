# Extra gateways for grmpf's hermes-desktop on amy, declared here so the
# app needs no manual setup. The spaces launcher (hermes/cli.nix,
# services.hermes-microvm.desktop.connections) renders the app's
# connections.json on every launch: this machine's own agent stays the
# window's primary; the entries below appear as `nix-<name>` in the
# Connections registry and in the sidebar's profile rail, and snap back
# if edited in the app. Entries the user adds in the app survive.
#
# som's agents run native in their own accounts and their web dashboards
# sit behind hermes' password gate (../hermes-dashboard-public.nix, bound
# 0.0.0.0), which rejects the app's static-token auth. So the desktop
# reaches them the way it can authenticate declaratively: the SSH
# connection kind. The app runs `hermes serve --isolated` over ssh as that
# account, tunnels the ephemeral port and adopts the token the remote
# mints. On som the command lands in spaces' host `hermes` shim, whose
# native arm exports the account's real HERMES_HOME, so it serves the
# same state (sessions, memories) the gateway and dashboard use. One
# `hermes serve` process per open connection, alive while the app is
# connected.
#
# Identity: its own passphrase-less ed25519 key (clan var below, private
# half deployed 0400 for grmpf), never the admin key. The app drives the
# system `ssh` with BatchMode and an `-i` at most, and never sets
# IdentitiesOnly, so with the default config every connect would first
# offer every agent identity - i.e. poke the TPM agent for a confirmation.
# The `Host` alias fixes that on the client side (the app passes the host
# field verbatim, so aliases work; port/key stay unset in the entry).
# The public half lands on som's dave-hermes account with `restrict` +
# port-forwarding only (machines/som/hermes-agents.nix reads it from this machine's
# vars): no pty, no agent/X11 forwarding, loopback forwards only, which is
# exactly the app's bootstrap (`-L 127.0.0.1:*:127.0.0.1:<port>`); the
# desktop's remote-terminal tab (needs a pty) is deliberately not served.
{ config, pkgs, ... }:
let
  key = config.clan.core.vars.generators.hermes-desktop-ssh.files.key.path;
in
{
  clan.core.vars.generators.hermes-desktop-ssh = {
    files.key = {
      owner = "grmpf";
      mode = "0400";
    };
    files."key.pub".secret = false;
    runtimeInputs = [ pkgs.openssh ];
    script = ''
      ssh-keygen -q -t ed25519 -N "" -C hermes-desktop@amy -f "$out"/key
    '';
  };

  programs.ssh.extraConfig = ''
    Host som-hermes
      HostName som.d
      User dave-hermes
      IdentityFile ${key}
      IdentitiesOnly yes
      IdentityAgent none
  '';

  services.hermes-microvm.desktop.connections.remotes.som-dave-hermes = {
    kind = "ssh";
    label = "dave-hermes on som";
    host = "som-hermes";
    # Required by the spaces option; same value the alias carries.
    user = "dave-hermes";
  };
}
