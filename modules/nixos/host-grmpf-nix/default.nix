{ config, pkgs, lib, inputs, ... }:
let
  l = lib // builtins;
in
{
  imports =
    [
      ../etc-hosts.nix
      inputs.home-manager.nixosModule
      inputs.retiolum.nixosModules.retiolum
      ./hardware-configuration.nix
      ./vpn.nix
      ./home-manager.nix
      ./fish.nix
      ./htop.nix
      ./dnscrypt.nix
      ./backup.nix
      ./retiolum.nix
      ./amdgpu.nix
      ./opengl.nix
      ./i3
      ./cura.nix  # slicer for 3d printing
      ./tplink-archer-t2u-nano.nix
      ./printing.nix
      ./nix-registry.nix
      ./low-battery-power-off.nix
      ./nixpkgs.nix
      ./nix-lazy.nix
      ./rbw.nix
      ./envfs.nix
      ./devenv.nix
      ./blueberry.nix
      ./nix-heuristic-gc.nix
      ./ollama.nix

  ];

  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  # NIX settings
  nix.package = inputs.nix.packages.x86_64-linux.default;
  nix.nixPath = [
    "tb=/home/grmpf/synced/projects/github/nix-toolbox"
    "nixpkgs=${pkgs.path}"
  ];
  nix.settings.max-jobs = 40;
  nix.nrBuildUsers = 100;
  nix.settings.trusted-users = [ "root" "grmpf" ];
  nix.settings.substituters = [
    "https://cache.nixos.org/"
    "https://nix-community.cachix.org"
    # "https://cache.ngi0.nixos.org/"
  ];
  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    # "cache.ngi0.nixos.org-1:KqH5CBLNSyX184S9BKZJo1LxrxJ9ltnY2uAs5c/f1MA="
  ];
  nix.optimise.dates = ["*:30"];
  # nix.optimise.automatic = true;
  # nix.gc.automatic = true;
  nix.gc.dates = "hourly";
  nix.gc.options = ''--delete-older-than 14d --max-freed "$((30 * 1024**3 - 1024 * $(df -P -k /nix/store | tail -n 1 | ${pkgs.gawk}/bin/awk '{ print $4 }')))"'';
  nix.extraOptions = ''
    sandbox = relaxed
    http2 = true
    http-connections = 200
    builders-use-substitutes = true
    experimental-features = nix-command flakes ca-derivations impure-derivations recursive-nix
    keep-outputs = true
    keep-derivations = true
    log-lines = 25
    min-free = ${l.toString (10*1000*1000*1000)}
    max-free = ${l.toString (20*1000*1000*1000)}
  '';
  /* nix.buildMachines = [ {
    hostName = "steam";
    # if the builder supports building for multiple architectures,
    # replace the previous line by, e.g.,
    systems = [ "x86_64-linux" "aarch64-linux" "armv7l-linux" ];
    maxJobs = 40;
    speedFactor = 20;
    supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
    mandatoryFeatures = [ ];
  }] ; */
  systemd.services.nix-daemon.environment.SSH_AUTH_SOCK = "/run/user/1000/ssh-agent";
  # nix.distributedBuilds = true;

  environment.sessionVariables.TERMINAL = [ "alacritty" ];
  environment.sessionVariables.TERM = [ "xterm-256color" ];
  environment.variables = {
    SSH_AUTH_SOCK = "/run/user/1000/ssh-agent";
  };

# SOFTWARE
  environment.systemPackages = with pkgs; [
  # cmdline tools
      # default tools
      wget vim killall file pv gptfdisk screen gnumake python3 jq fx eza
      # version control
      git gti gitg github-cli tig ghq h github-cli lazygit git-absorb
      # search
      ripgrep nix-index
      # dafult tools crazy editions
      bat fd sl
      # network tools
      iodine macchanger mosh nmap sipcalc sshpass sshuttle traceroute wireguard-tools
      # compression tools
      lz4 pxz zip unzip
      # system analysis
      baobab bmon btop nix-top s-tui pciutils powertop usbutils lsof dstat latencytop sysprof filelight nvme-cli
      # nix tools
      comma nix-output-monitor nix-prefetch-git nixos-generators nix-tree nix-diff cntr
      inputs.nil.packages.x86_64-linux.nil
      # fs tools
      sshfs-fuse ranger mc
      # virtualisation
      podman-compose vagrant arion qemu docker-compose
      # cloud stuff
      google-cloud-sdk
      # penetration tools
      aircrack-ng metasploit
      # i3 dependencies
      brightnessctl playerctl
      # other utils
      udiskie # automatically mount stuff
      # formatters
      alejandra
      # haskell
      ghc
      # rust
      cargo rustc gcc
      # backups
      restic
      # appimage
      appimage-run
      # clan
      inputs.clan-core.packages.x86_64-linux.clan-cli
      # AI
      ollama

  # GUI tools
      arandr  # configure monitors
      blender  # graphics software
      ferdium  # all chat apps in one program
      blueberry  # maage bluetooth devices
      kcalc # calculator
      ark # archive viewer/extractor
      # chia # blockchain
      httpie # make http requests
      flameshot kazam # screen shot + recoding
      psensor # watch Sensors
      libreoffice # office
      gparted # partitioning
      sqlitebrowser # browser for sqlite
      pavucontrol # audio settings
      pulseaudio
      wireshark
      # file manager
        dolphin filezilla gnome3.nautilus xfce.thunar gnome.eog pcmanfm
      # browser
        firefox chromium
      # media viewer
        vlc okular gwenview
      # graphical tools
        gimp spectacle inkscape darktable
      # 3d tools
        freecad
      # IDEs and text editors
        jetbrains.pycharm-community
      # messengers
        tdesktop element-desktop
      # torrent
        deluge
      # gaming
        openra
      # VPN
        mullvad-vpn protonvpn-gui
      # wallets
        ledger-live-desktop
  ];
  programs.vim.defaultEditor = true;
  programs.nm-applet.enable = true;
  programs.adb.enable = true;
  programs.steam.enable = true;
  programs.wireshark.enable = true;
  hardware.ledger.enable = true;
  services.fwupd.enable = true;
  services.smokeping.enable = true;
  programs.sysdig.enable = true;
  services.usbmuxd.enable = true;
  services.udisks2.enable = true;
  # programs.starship.enable = true;
  # services.nscd.enableNsncd = true;

  # block middle click paste
  systemd.services.xmousepasteblock = {
    script = "${pkgs.xmousepasteblock}/bin/xmousepasteblock";
  };

  # Set your time zone.
  # time.timeZone = "Europe/Berlin";
  services.tzupdate.enable = true;

  # BOOTLOADER
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

  # KERNEL
    boot.initrd.availableKernelModules = [ "ahci" "sdhci_pci" ];
    # boot.kernelPackages = pkgs.linuxPackages_5_4;

  # FILESYSTEMS
    boot.tmp.useTmpfs = true;
    boot.tmp.tmpfsSize = "80%";
    boot.supportedFilesystems = [ "ntfs" "exfat" "zfs" "apfs" "cifs" "smb" ];
    boot.initrd.supportedFilesystems = ["zfs"];
    # required by zfs
    networking.hostId = "5eb1bf28";

  # TLP
  services.tlp.enable = true;
  services.tlp.settings = {
    CPU_SCALING_GOVERNOR_ON_AC = "performance";
    CPU_SCALING_GOVERNOR_ON_BAT = "powersave";
    CPU_MAX_PERF_ON_AC = 100;
    STOP_CHARGE_THRESH_BAT0 = 90;
    START_CHARGE_THRESH_BAT0 = 80;
    CPU_SCALING_MAX_FREQ_ON_BAT = 800000;
    CPU_SCALING_MAX_FREQ_ON_AC = 9999999;
    CPU_MAX_PERF_ON_BAT=20;
  };

  # BORING STUFF.
  console.font = "Lat2-Terminus16";
  console.keyMap = "us";
  i18n = {
    defaultLocale = "en_US.UTF-8";
  };

  # List services that you want to enable:
  programs.ssh.startAgent = true;
  programs.ssh.agentTimeout = "1h";
  programs.mtr.enable = true;

  # ssh server
  #services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;

# BLUETOOTH
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  # hack for xbox controller:
  # boot.extraModprobeConfig = ''
  #   options bluetooth disable_ertm=1
  #   options kvm_intel nested=1
  #   options kvm_intel emulate_invalid_guest_state=0
  #   options kvm ignore_msrs=1
  # '';

# AUDIO
  sound.enable = true;
  services.pipewire.enable = true;
  services.pipewire.alsa.enable = true;
  services.pipewire.pulse.enable = true;
  services.pipewire.jack.enable = true;
  services.gnome.gnome-keyring.enable = true;
  services.pipewire.socketActivation = false;
  systemd.user.services.pipewire.wantedBy = ["graphical-session.target"];
  systemd.user.services.pipewire-pulse.wantedBy = ["pipewire.service"];
  # systemd.user.services.pipewire.wantedBy = ["graphical-session.target"];
  # security.rtkit.enable = true;
  # services.pipewire.systemWide = true;

  services.hardware.bolt.enable = true;

# VIDEO
  services.xserver.videoDrivers = [ "modesetting" ];

# DESKTOP (GUI)
  # Enable the X11 windowing system.
  services.xserver.enable = true;
  services.xserver.libinput.enable = true;
  services.xserver.layout = "us";
  services.xserver.xkbVariant = "altgr-intl";
  services.xserver.xkbOptions = "eurosign:e";

  # services.xserver.xautolock = {
  #   enable = true;
  #   time = 5;
  # };


# USERS
  users.mutableUsers = false;
  users.users.root.hashedPassword = "$6$.Op44MVHQ3qw$YwbFuIrs37BiAScgJSXAIcTxLjFL4ziejub.VBj.Xt41Pm3C8QilLjI2yW6R2lit1RnLydmTwDqzuQa/WUlor.";
  users.users.grmpf = {
    isNormalUser = true;
    hashedPassword = "$6$.Op44MVHQ3qw$YwbFuIrs37BiAScgJSXAIcTxLjFL4ziejub.VBj.Xt41Pm3C8QilLjI2yW6R2lit1RnLydmTwDqzuQa/WUlor.";
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk grmpf@grmpf-ThinkPad-T460p" ];
    # wheel enables ‘sudo’ for the user.
    extraGroups = [ "wheel" "networkmanager" "audio" "ledger" "plugdev" ];
    # shell = pkgs.fish;
  };

# VIRTUALIZATOIN
  # qemu
  boot.binfmt.emulatedSystems = [ "aarch64-linux" "armv7l-linux" ];

  virtualisation.docker.enable = true;
  virtualisation.podman.enable = true;
  virtualisation.waydroid.enable = true;
  # virtualisation.podman.dockerSocket.enable = true;
  virtualisation.podman.extraPackages = [ pkgs.zfs ];
  systemd.services.podman.serviceConfig = {
    ExecStart = [ "" "${config.virtualisation.podman.package}/bin/podman --storage-driver zfs $LOGGING system service" ];
  };
# virtualbox
  virtualisation.virtualbox.host.enable = true;
  users.extraGroups.vboxusers.members = [ "grmpf" ];
  #virtualisation.virtualbox.host.enableExtensionPack = true;

  #libvirtd
  virtualisation.libvirtd.enable = true;
  users.extraUsers.grmpf.extraGroups = [ "libvirtd" "podman" ];
  /* networking.firewall.checkReversePath = false; */

# gaming
  hardware.opengl.driSupport32Bit = true;
  hardware.pulseaudio.support32Bit = true;

# shell aliases
  environment.shellAliases = {
    dco = "sudo docker-compose";
    docker = "sudo docker";
    arion = "sudo arion";
    ssh = "env TERM=xterm-color ssh";
    nix-buildr = ''nix-build --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    nixr = ''nix --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    mkcd = ''bash -c 'dir=$1 && mkdir -p $dir && cd $dir' '';
  };


# FIREWALL
  networking.firewall.allowedTCPPorts = [ 631 655 ];
  networking.firewall.allowedUDPPorts = [ 26000 631 655 ];
  networking.firewall.allowPing = true;
  boot.kernelModules = [ "br_netfilter" "xboxdrv" ];
  boot.kernel.sysctl = {
    # See https://wiki.libvirt.org/page/Net.bridge.bridge-nf-call_and_sysctl.conf for background information
    "net.bridge.bridge-nf-call-iptables" = 0;
  };


# NETWORKING
  networking.hostName = "grmpf-nix"; # Define your hostname.
  networking.domain = "grmpf";
  networking.networkmanager.enable = true;
  networking.nameservers = [
    "127.0.0.1"
    "::1"
  ];
  networking.dhcpcd.extraConfig = "nohook resolv.conf";
  networking.networkmanager.dns = lib.mkForce "none";
  # networking.networkmanager.insertNameservers = [
  #   "8.8.8.8"
  # ];

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "19.03"; # Did you read the comment?
}
