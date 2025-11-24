# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, lib, pkgs, inputs, self, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      inputs.srvos.nixosModules.mixins-systemd-boot
      ../../modules/nixos/common.nix
      ../../modules/nixos/common-tools.nix
      ../../modules/nixos/monitoring.nix
      ../../modules/nixos/role-parasit.nix
      ../../modules/nixos/role-sshuttle-server
      ../../modules/nixos/role-iodine/default.nix
      ../../modules/nixos/dyndns-porkbun.nix
      ../../modules/nixos/hyprspace
      ../../modules/nixos/nix-caches.nix
      ./automount
      ./hardware-configuration.nix
      ./smokeping.nix
      # ./sync-from-manu.nix
      ./users.nix
      ./reverse-proxy.nix
      ./file-browser-roman.nix
    ];

  # services.hyprspace.settings.peers = [
  #   { id = self.nixosConfigurations.grmpf-nix.config.clan.core.vars.generators.hyprspace.files.peer-id.value; }
  # ];

  clan.core.networking.targetHost = "root@nas";

  documentation.nixos.enable = false;
  documentation.man.enable = false;

  nixpkgs.hostPlatform = "x86_64-linux";

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.requestEncryptionCredentials = false;

  # kernel
  # WOL doesn't work if r8169 used
  # boot.blacklistedKernelModules = [ "r8169" ];
  boot.extraModulePackages = [
    # needed for gigabit ethernet adapter, since r8169 is disabled above
    # TODO: currently broken, but could be updated in nixpkgs
    # config.boot.kernelPackages.r8168


    # config.boot.kernelPackages.rtl8821au
    # config.boot.kernelPackages.rtl88x2bu
    # BrosTrend wifi stick
    (pkgs.linuxPackages.rtl8812au.override {
      kernel = config.boot.kernelPackages.kernel;
    })
  ];

  # power
  powerManagement.cpuFreqGovernor = "ondemand";

  virtualisation.docker.enable = true;

  networking.hostName = "nas"; # Define your hostname.
  networking.hostId = "d523969b"; # Define your hostname.
  networking.useDHCP = true;
  # networking.interfaces.enp3s0.useDHCP = true;
  # networking.interfaces.enp3s0.ipv4.addresses = [
  #   { address = "192.168.178.2"; prefixLength = 24; }
  # ];
  networking.interfaces.enp0s20u7.ipv4.addresses = [
    { address = "10.99.99.1"; prefixLength = 24; }
  ];
  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "af415e486f4514ce"  # home
    "12ac4a1e71b04480"  # manu
    "363c67c55a553deb"  # papa
  ];

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = lib.mkForce null;
  programs.mosh.enable = true;

  # banning
  # fail2nix enables sshd module by default
  # services.fail2ban.enable = true;

  # mDNS
  services.avahi.enable = true;

  environment.systemPackages = with pkgs; [
    borgbackup
    htop
    screen
    vim
  ];

  # dyndns
  services.porkbun.ipv4Entries = [
    "bruch-bu.de/A/casa"
    "bruch-bu.de/A/playa"
  ];
  services.porkbun.ipv6Entries = [
    "bruch-bu.de/AAAA/casa"
  ];

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

