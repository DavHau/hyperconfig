/*
  Unified ssh client key for the nix daemon.

  One ed25519 keypair, generated once via clan vars (share = true) and
  deployed to every machine importing this module (all laptops via
  laptop-dave.nix — currently amy and vit).

  The private key is symlinked to /root/.ssh/id_ed25519 at activation, so it
  becomes root's default ssh identity — the nix daemon runs as root and, for
  an ad-hoc `--builder ssh://host`, spawns ssh that picks it up automatically
  with no per-builder wiring.

  The public key is committed in plaintext at
  vars/shared/nix-ssh-client/ssh.id.pub/value so it can be pasted into
  the remote builders' authorized_keys (those builders are managed in
  other repos).
*/
{ config, pkgs, lib, ... }:
let
  key = config.clan.core.vars.generators.nix-ssh-client.files."ssh.id";
in
{
  clan.core.vars.generators.nix-ssh-client = {
    share = true;

    files."ssh.id" = {
      secret = true;
      group = "root";
      mode = "0400";
    };
    files."ssh.id.pub" = {
      # public: owners grant it to remote builders
      secret = false;
    };

    runtimeInputs = [ pkgs.openssh ];

    script = ''
      ssh-keygen -t ed25519 -N "" -C "nix-daemon-client" -f "$out"/ssh.id
    '';
  };

  # The nix daemon runs as root and, for an ad-hoc `--builder ssh://host`,
  # spawns ssh as root with no explicit key, which uses root's default
  # identity (/root/.ssh/id_ed25519). Symlink the unified key there so any
  # builder just works with no per-builder wiring.
  system.activationScripts.nix-ssh-client = lib.stringAfter [ "users" ] ''
    install -d -m 0700 -o root -g root /root/.ssh
    ln -sfn '${key.path}' /root/.ssh/id_ed25519
  '';
}
