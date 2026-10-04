# AM5 desktop, iGPU only. Hardware detail lives in ./facter.json.
{ inputs, ... }:
{
  imports = [
    inputs.nixos-hardware.nixosModules.common-cpu-amd
    inputs.nixos-hardware.nixosModules.common-cpu-amd-pstate
    inputs.nixos-hardware.nixosModules.common-gpu-amd
    inputs.nixos-hardware.nixosModules.common-pc-ssd
    ../../modules/nixos/dave.nix
    ../../modules/nixos/user-dave.nix
    ../../modules/nixos/amdgpu.nix
    ../../modules/nixos/zfs-remote-unlock
    ../../modules/nixos/tang-server.nix
    ./disko.nix
    ../../modules/nixos/storagebox.nix
    ../../modules/nixos/vault-nfs-client.nix
    ../../modules/nixos/users/hsjobeki-vault.nix
    ./hermes-agents.nix
    ../../modules/nixos/hermes-claude-auth.nix
    ../../modules/nixos/public-ipv6-token.nix
    ../../modules/nixos/linger-normal-users.nix
    ../../modules/nixos/rgb-off.nix
    ../../modules/nixos/cooler-lcd
    ../../modules/nixos/ipv4-forward.nix
    ../../modules/nixos/container-slots.nix
  ];

  # Public IPv4 38.89.142.76, borrowed from sgp through a WireGuard tunnel
  # (../../modules/nixos/ipv4-forward.nix); this firewall still decides which
  # ports answer.
  hyper.ipv4Forward.role = "backend";

  # r8169 is the only NIC that matters; the initrd needs it to be reachable
  # for unlock (../../modules/nixos/zfs-remote-unlock, wired only).
  boot.initrd.availableKernelModules = [ "r8169" ];

  # The 1 GiB ESP holds one ~80 MiB initrd per distinct generation; with no
  # cap ~100 entries kept 13 of them and filled it.
  boot.loader.systemd-boot.configurationLimit = 20;

  # Boot unlock without a passphrase while vit is up
  # (../../modules/nixos/tang-server.nix); som serves vit in turn, for when
  # vit's initrd can reach the LAN. bam stays out: its root is not
  # encrypted, so its Tang keys would leave with it.
  hyper.zfsRemoteUnlock.tang = {
    servers = [ "vit" ];
    interface = "enp6s0";
  };
  hyper.tangServer = {
    enable = true;
    interface = "br0";
    address = "fe80::7a6e:1";
    networkdUnit = "40-br0";
  };

  # No wifi on this desktop: it sits on the LAN cable. The AX210 stays
  # unbound (no wlan0, no supplicant, no initrd PSK); nixos-facter's
  # wlan0 network unit just never matches.
  boot.blacklistedKernelModules = [ "iwlwifi" ];

  # RAM and the cooler's fans/water block (on the board's ARGB headers) dark.
  hyper.rgbOff.colorfulArgb = true;

  # Thermalright AIO LCD (0416:5302); its port is cut 22:00-07:00
  # (../../modules/nixos/cooler-lcd).
  hyper.coolerLcd.usbPort = "1-0:1.0/usb1-port8";

  # Public hermes dashboards: https://hermes.davhau.com/ (AAAA -> the token
  # address below), pocket-id login through oauth2-proxy, each account
  # routed to its own backend. Every agent in ./hermes-agents.nix is published.
  hyper.hermesDashboard.host = "hermes.davhau.com";

  # Public address 2405:9800:b901:94e3::c0de:ba5e on the LAN bridge (prefix
  # from the RA, ../../modules/nixos/public-ipv6-token.nix); the matching AIS
  # router allow rule is `router-ais ipv6-rules list` -> "som".
  networking.publicIPv6 = {
    token = "::c0de:ba5e";
    interface = "br0";
  };

  # Container slots for other repos to deploy into
  # (../../modules/nixos/container-slots.nix). enp6s0 is a port of br0,
  # which keeps its MAC and carries som's own DHCP/SLAAC addresses. Add a
  # slot as `slots.<name> = { id; mode; }`.
  hyper.containerSlots = {
    enable = true;
    uplink = "enp6s0";
    uplinkMac = "a4:0c:66:1b:29:f1";
    # root's key in the bootstrap system every slot starts with.
    deployKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU agent@amy"
    ];

    # v6 2405:9800:b901:94e3::5107:1, v4 from the LAN's DHCP.
    slots.asof = {
      id = 1;
      mode = "lan";
      # Writes land on bam as slot-asof:vault-parquet-rw, which bam's ACLs
      # admit on /vault/parquet only (../../modules/nixos/vault-ids.nix).
      shares."/vault/parquet" = {
        source = "/vault/parquet";
        user = "slot-asof";
      };
    };

    # The mm project. v6 2405:9800:b901:94e3::5107:2, v4 from the LAN's DHCP.
    slots.mm = {
      id = 2;
      mode = "lan";
      # Writes land on bam as slot-mm:vault-parquet-rw, as for asof.
      shares."/vault/parquet" = {
        source = "/vault/parquet";
        user = "slot-mm";
      };
    };
  };
  users.users.slot-asof = {
    isSystemUser = true;
    uid = 1201;
    group = "vault-parquet-rw";
    description = "asof container slot's identity on /vault/parquet";
  };
  users.users.slot-mm = {
    isSystemUser = true;
    uid = 1202;
    group = "vault-parquet-rw";
    description = "mm container slot's identity on /vault/parquet";
  };

  # The spaces desktop profile defaults llama-swap on, which registers a
  # local provider in every harness's models.yml (omp-common.nix) and in the
  # hermes settings, and omp picks it as the first-run default. som's iGPU
  # is not a brain; p0 is (hermes-common.nix). Off, as on vit.
  services.llama-swap.enable = false;

  system.stateVersion = "25.11";
}
