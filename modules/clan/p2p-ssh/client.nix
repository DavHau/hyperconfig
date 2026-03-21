# ===========================================================================
# Client — reach the server's sshd via dumbpipe over iroh
# ===========================================================================
#
# SETUP:
#   1. Get the ticket from the server's journal:
#        journalctl -u dumbpipe-ssh -n 20     (on the server)
#
#   2. Store it in /etc/dumbpipe-ssh-ticket (readable only by root):
#        echo "endpoint..." > /etc/dumbpipe-ssh-ticket
#        chmod 600 /etc/dumbpipe-ssh-ticket
#
#   3. Deploy this config. Then:
#        ssh -p 2222 youruser@127.0.0.1
#
#   Optional: add to ~/.ssh/config:
#     Host myserver
#       HostName 127.0.0.1
#       Port 2222
#       User youruser
# ===========================================================================

{ config, pkgs, lib, ... }:

{
  # -------------------------------------------------------------------
  # 1. dumbpipe service — tunnel localhost:2222 to the server's sshd
  # -------------------------------------------------------------------
  systemd.services.dumbpipe-ssh = {
    description = "SSH tunnel to server via dumbpipe (iroh)";
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    script = ''
      exec ${pkgs.dumbpipe}/bin/dumbpipe connect-tcp \
        --addr 127.0.0.1:2222 \
        "$(cat /etc/dumbpipe-ssh-ticket)"
    '';

    serviceConfig = {
      Type       = "simple";

      Restart    = "always";
      RestartSec = 10;

      DynamicUser = true;

      # Hardening
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      NoNewPrivileges = true;
    };
  };

  # -------------------------------------------------------------------
  # 2. Convenience
  # -------------------------------------------------------------------
  environment.systemPackages = [ pkgs.dumbpipe ];
}
