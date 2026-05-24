{...}: {
  users.users.git = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      # DavHau
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwzL0rt4J+kzggV4pFXf9yh9zBF6n4hdXXVbCB7p1x6"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU"
      # shoutingcatana
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO/PPzetdVPjZhFumovpMO8Wc3BP05bBEbrg+C0iMhDo"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBQFA3rj3sI/dPwGjumlHuKbWvkdM0jVyViIhjIpYrLe"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEdIBdPl5ZMBR8JX7noIY+Zpj2nbHhcVFV4LC/3NWc48"
    ];
  };
}
