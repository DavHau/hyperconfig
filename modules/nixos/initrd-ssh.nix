# sshd in the initrd on port 2222: the recovery path into a machine that
# waits for its disk passphrase. Logins: root's authorized keys.
#
# The host key is a clan var, not the machine's own: the initrd lives
# unencrypted in the ESP. neededFor = activation uploads it before the
# switch and keeps it, so append-initrd-secrets finds it on a `boot`-only
# switch too. Pin it from the repo:
#   vars/per-machine/<m>/initrd-ssh/ssh_host_ed25519_key.pub/value
#
# (som's ./zfs-remote-unlock predates this and generates its key on the
# machine.)
{ config, lib, pkgs, ... }:
let
  key = config.clan.core.vars.generators.initrd-ssh.files.ssh_host_ed25519_key;
in
{
  options.hyper.initrdSsh.enable = lib.mkEnableOption "sshd in the initrd";

  config = lib.mkIf config.hyper.initrdSsh.enable {
    clan.core.vars.generators.initrd-ssh = {
      files.ssh_host_ed25519_key.neededFor = "activation";
      files."ssh_host_ed25519_key.pub".secret = false;
      runtimeInputs = [ pkgs.openssh ];
      script = ''
        ssh-keygen -q -t ed25519 -N "" -C "${config.networking.hostName}-initrd" \
          -f "$out"/ssh_host_ed25519_key
      '';
    };

    boot.initrd.network.enable = true;
    boot.initrd.systemd.network.enable = true;
    boot.initrd.network.ssh = {
      enable = true;
      port = 2222;
      hostKeys = [ key.path ];
      # authorizedKeys defaults to users.users.root.openssh.authorizedKeys.keys.
    };
  };
}
