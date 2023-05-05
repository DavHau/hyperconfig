# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, pkgs-unstable, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./users.nix
      ./age.nix
      ./monit
      ../nix/modules/nixos/sshuttle-server
      ../deployment.nix
    ];

  deployAddress = "rhauer.duckdns.org";

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.requestEncryptionCredentials = false;

  # kernel
  # WOL doesn't work if r8169 used
  boot.blacklistedKernelModules = [ "r8169" ];
  boot.extraModulePackages = [
    config.boot.kernelPackages.r8168
    # config.boot.kernelPackages.rtl8821au
    config.boot.kernelPackages.rtl88x2bu
    # BrosTrend wifi stick
    # (pkgs-unstable.linuxPackages.rtl8812au.override {
    #   kernel = config.boot.kernelPackages.kernel;
    # })
  ];

  # power
  powerManagement.cpuFreqGovernor = "ondemand";

  # wifi
  networking.wireless.enable = true;
  networking.wireless.networks.Parasit_5G.psk = "@PW@";
  networking.wireless.networks.Parasit_5G.priority = 10;
  networking.wireless.networks.Parasit.psk = "@PW@";
  networking.wireless.environmentFile = config.age.secrets.wifi-parasit.path;

  networking.hostName = "nas"; # Define your hostname.
  networking.hostId = "d523969b"; # Define your hostname.
  networking.useDHCP = true;
  networking.interfaces.enp3s0.useDHCP = true;
  # networking.interfaces.enp3s0.ipv4.addresses = [
  #   { address = "192.168.178.2"; prefixLength = 24; }
  # ];
  networking.interfaces.enp0s20u7.ipv4.addresses = [
    { address = "10.99.99.1"; prefixLength = 24; }
  ];
  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce"
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.passwordAuthentication = false;
  programs.mosh.enable = true;

  # banning
  # fail2nix enables sshd module by default
  services.fail2ban.enable = true;

  # mDNS
  services.avahi.enable = true;

  environment.systemPackages = with pkgs; [
    (pkgs.writeScriptBin
      "enter-password"
      (builtins.readFile ./enter-password.sh))
    htop
    vim
  ];

  # samba
  services.samba-wsdd.enable = true;
  services.samba = {
    enable = true;
    openFirewall = true;
    securityType = "user";
    extraConfig = ''
      workgroup = WORKGROUP
      server string = smbnix
      netbios name = smbnix
      security = user
      #use sendfile = yes
      #max protocol = smb2
      hosts allow = 192.168.178.0/24  localhost
      hosts deny = 0.0.0.0/0
      guest account = guest
      map to guest = bad user
    '';
    shares = {
      public = {
        path = config.users.users.guest.home;
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force user" = "guest";
        # "force group" = "guest";
      };
      # private = {
      #   path = "/mnt/Shares/Private";
      #   browseable = "yes";
      #   "read only" = "no";
      #   "guest ok" = "no";

      #   "create mask" = "0644";
      #   "directory mask" = "0755";
      #   "force user" = "username";
      #   "force group" = "groupname";
      # };
    };
  };

  systemd.services.automount = {
    description = "Automount Encrypted Dataset";
    after = [
      "network-online.target"
    ];
    before = [
      # "nfs-server.service"
    ];
    wantedBy = [
      "multi-user.target"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
    path = with pkgs; [
      openssh
      zfs
    ];
    preStart = ''
      set -ex
      if ! cat /run/passwd_enc >/dev/null; then
        passwd=$(ssh root@10.99.99.2 cat /tmp/passwd_enc)
      else
        passwd=$(cat /run/passwd_enc)
      fi
      enc_datasets="pool11/enc rpool/enc"
      for ds in $enc_datasets; do
        echo $passwd | zfs load-key $ds && echo "key loaded successfully"
      done
      zfs mount -a && echo "all datasets mounted successfully"
      exit $?
    '';
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;
  networking.firewall.extraCommands =
    ''iptables -t raw -A OUTPUT -p udp -m udp --dport 137 -j CT --helper netbios-ns'';

  fileSystems."/pool11" =
    { device = "pool11";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

  system.stateVersion = "21.11"; # Did you read the comment?
}

