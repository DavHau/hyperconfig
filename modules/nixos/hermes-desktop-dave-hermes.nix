# dave-hermes (som's native agent, machines/som/hermes-agents.nix) as a
# gateway in hermes-desktop, reached as dave-hermes@hermes.davhau.com over
# ssh. Imported by ./dave.nix, so every dave desktop machine carries it.
#
# Why ssh and not the https dashboard: som's dashboards sit behind
# oauth2-proxy (./hermes-dashboard-public.nix), which rejects the app's
# static-token auth. The SSH connection kind needs no token: the app runs
# `hermes serve --isolated` as dave-hermes over ssh, tunnels the ephemeral
# port and adopts the token the remote mints. On som the command lands in
# spaces' host `hermes` shim, whose native arm exports the account's real
# HERMES_HOME, so it serves the same state (sessions, memories) the gateway
# and dashboard use. One `hermes serve` per open connection.
#
# Identity: one passphrase-less ed25519 key for the fleet (shared clan var
# below), never the admin key. The var itself stays root 0400; activation
# copies it to /run/hermes-desktop-ssh/<user>, owner-only, for dave plus
# grmpf where that account exists (amy). Per-uid owners, not a shared
# group: a group added at deploy time is missing from every session that
# was already running (the app then fails with `Load key ...: Permission
# denied` until a re-login); ownership needs no new login.
# The public half lands on som's dave-hermes account with `restrict` +
# loopback port-forwarding only: exactly the app's bootstrap
# (`-L 127.0.0.1:*:127.0.0.1:<port>`); no pty, so the desktop's
# remote-terminal tab is deliberately not served.
#
# The app drives the system `ssh` with BatchMode and an `-i` at most, never
# IdentitiesOnly, so with the default config every connect would first offer
# every agent identity - i.e. poke the TPM agent for a confirmation. The
# Match block fixes that client-side for exactly this user@host; other
# accounts on hermes.davhau.com keep the normal identities. BatchMode
# cannot answer a TOFU prompt, so the host is verified as `som.d`: som
# presents its clan sshd CA certificate (principal som.d) on every address,
# and the sshd client role trusts that CA for `*.d` in ssh_known_hosts.
# Nothing here reads som's config or vars.
#
# The spaces launcher (hermes/cli.nix, services.hermes-microvm.desktop
# .connections) renders the entry as `nix-dave-hermes` into the app's
# connections.json on every launch, for every user it launches for; edits
# in the app snap back, entries the user adds survive.
{ config, lib, pkgs, ... }:
let
  host = "hermes.davhau.com";
  user = "dave-hermes";
  key = config.clan.core.vars.generators.hermes-desktop-ssh.files.key.path;
  keyDir = "/run/hermes-desktop-ssh";
  users = [ "dave" ] ++ lib.optional (config.users.users ? grmpf) "grmpf";
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
    Match host ${host} user ${user}
      IdentityFile ${keyDir}/%u
      IdentitiesOnly yes
      IdentityAgent none
      HostKeyAlias som.d
  '';

  services.hermes-microvm.desktop.connections.remotes.${user} = {
    kind = "ssh";
    label = "dave-hermes";
    inherit host user;
  };
}
