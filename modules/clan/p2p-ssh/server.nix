# ===========================================================================
# Server — expose sshd via dumbpipe over iroh
# ===========================================================================
#
# FIRST-TIME SETUP:
#   1. Generate a secret key:
#        nix-shell -p dumbpipe --run "dumbpipe listen"
#      Copy the "using secret key ..." line. Ctrl+C.
#
#   2. Store it in /etc/dumbpipe-ssh.secret (readable only by root):
#        echo "THE_HEX_KEY" > /etc/dumbpipe-ssh.secret
#        chmod 600 /etc/dumbpipe-ssh.secret
#
#   3. Deploy this config. The service will start and print a ticket
#      to the journal. Grab it with:
#        journalctl -u dumbpipe-ssh -n 20
#      Give that ticket to the client.
#
#   4. On subsequent restarts the ticket changes (new address hints)
#      but old tickets keep working — iroh discovery resolves by
#      node ID regardless.
# ===========================================================================

{ pkgs, ... }:

{
  services.openssh.enable = true;

  # -------------------------------------------------------------------
  # dumbpipe service — forward iroh connections to sshd
  # -------------------------------------------------------------------
  systemd.services.dumbpipe-ssh = {
    description = "Expose sshd via dumbpipe (iroh)";
    after    = [ "network-online.target" "sshd.service" ];
    wants    = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${pkgs.dumbpipe}/bin/dumbpipe listen-tcp --host 127.0.0.1:22";

      # Load the secret key for a stable node ID
      EnvironmentFile = "/etc/dumbpipe-ssh.secret";

      Restart    = "always";
      RestartSec = 5;

      # Run as a dedicated user — dumbpipe needs no privileges
      DynamicUser = true;

      # Hardening
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      NoNewPrivileges = true;
    };
  };
}
