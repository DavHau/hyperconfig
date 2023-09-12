{lib, pkgs, ...}: {
  services.samba-wsdd.enable = true; # make shares visible for windows 10 clients
  services.samba.openFirewall = true;
  networking.firewall.allowedTCPPorts = [
    5357 # wsdd
  ];
  networking.firewall.allowedUDPPorts = [
    3702 # wsdd
  ];
  services.samba = {
    enable = true;
    securityType = "user";
    extraConfig = ''
      workgroup = WORKGROUP
      server string = smbnix
      netbios name = smbnix
      security = user
      #use sendfile = yes
      #max protocol = smb2
      # note: localhost is the ipv6 localhost ::1
      hosts allow = 192.168.178. 10.241. 127.0.0.1 localhost
      hosts deny = 0.0.0.0/0
      # guest account = guest
      # map to guest = bad user

      # ensures that smb user will be mapped to unix user
      username map = ${pkgs.writeText "smbusers" ''
        manu = manu
      ''}
    '';
    shares = {
      # public = {
      #   path = "/test2";
      #   browseable = "yes";
      #   "read only" = "no";
      #   "guest ok" = "yes";
      #   "create mask" = "0644";
      #   "directory mask" = "0755";
      #   "force user" = "manu";
      #   "force group" = "users";
      # };
      # mount via:
      #   sudo mount -t cifs -o user=manu //10.241.225.42/manu /mnt/1
      manu = {
        path = "/raid/manu";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        # requires setting a password via `smbpasswd -a`
        "force user" = "manu";
        "force group" = "users";
        # Apple fixes for SMB
        #   Fixes: The operation can't be complete because the item XXX is in use.
        "fruit:aapl" = "yes";
        "fruit:time machine" = "yes";
        "vfs objects" = "catia fruit streams_xattr";
      };
    };
  };
}
