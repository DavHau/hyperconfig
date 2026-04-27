{ pkgs, inputs, ... }:
{
  environment.systemPackages = with pkgs; [
    # cmdline tools
    signal-desktop
    # default tools
    wget vim killall file pv gptfdisk screen gnumake python3 jq fx eza
    # version control
    git gti gitg github-cli tig ghq h github-cli lazygit git-absorb jujutsu jjui
    # search
    ripgrep nix-index
    # default tools crazy editions
    bat fd sl
    # network tools
    iodine macchanger mosh nmap sipcalc sshpass sshuttle traceroute wireguard-tools
    # compression tools
    lz4 pxz zip unzip
    # system analysis
    baobab bmon btop s-tui pciutils powertop usbutils lsof dool sysprof nvme-cli
    # nix tools
    comma nix-output-monitor nix-prefetch-git nixos-generators nix-tree nix-diff cntr
    inputs.nil.packages.x86_64-linux.nil nix-init nix-fast-build
    # fs tools
    sshfs-fuse ranger mc
    # virtualisation
    podman-compose arion qemu docker-compose
    # cloud stuff
    google-cloud-sdk
    # penetration tools
    aircrack-ng metasploit
    # i3 dependencies
    brightnessctl playerctl
    # other utils
    udiskie  # automatically mount stuff
    # formatters
    alejandra
    # rust
    cargo rustc gcc
    # appimage
    appimage-run
    # clan
    inputs.clan-core.packages.x86_64-linux.clan-cli
    # AI
    ollama
    # python
    ruff
    # show community maintained examples for linux commands
    cheat
    # man
    man-pages
    # serial console for hardware debugging
    minicom
    # AI
    # aider-chat-full
    inputs.llm-agents.packages.${pkgs.system}.claude-code

    delta
    lsd

    # GUI tools
    arandr  # configure monitors
    # blender  # graphics software
    # ark  # archive viewer/extractor
    # kcalc  # calculator
    httpie  # make http requests
    flameshot  # screen shot + recording
    # psensor  # watch Sensors
    libreoffice  # office
    gparted  # partitioning
    # sqlitebrowser  # browser for sqlite
    pavucontrol  # audio settings
    wireshark
    # editors
    # file manager
    filezilla nautilus eog
    # browser
    firefox chromium
    # media viewer
    vlc freetube
    # graphical tools
    gimp inkscape
    # darktable
    # 3d tools
    # freecad
    # messengers
    ferdium  # all chat apps in one program
    # torrent
    deluge
    # gaming
    moonlight-qt
    # VPN
    mullvad-vpn protonvpn-gui
    # wallets
    ledger-live-desktop
    # VMs
    quickemu
    # edit PDF files
    xournalpp
    # games
    xonotic
  ];

  # programs.nix-ld.enable = true;
  programs.vim.enable = true;
  programs.vim.defaultEditor = true;
  programs.nm-applet.enable = true;
  programs.steam.enable = true;
  programs.wireshark.enable = true;
  hardware.ledger.enable = true;
  services.fwupd.enable = true;
  # services.smokeping.enable = true;
  programs.sysdig.enable = true;
  services.usbmuxd.enable = true;
  services.udisks2.enable = true;
  services.localtimed.enable = true;
  services.geoclue2.enable = true;
  # programs.starship.enable = true;
  # services.nscd.enableNsncd = true;
  # services.unifi.enable = true;

  services.hardware.bolt.enable = true;
}
