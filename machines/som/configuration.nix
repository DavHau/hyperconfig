# AM5 desktop, iGPU only. Hardware detail lives in ./facter.json.
{
  config,
  inputs,
  lib,
  ...
}:
let
  # Mullvad egress rollout (../../modules/nixos/mullvad-egress): 1 = only
  # the benchmark user, 2 = also every hermes agent and SearXNG.
  mullvadStage = 2;
  agents = lib.attrNames config.hyper.hermesAgents;
  hermesLib = import ../../modules/nixos/hermes-native/lib.nix { inherit lib; };
in
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
    ../../modules/nixos/user-manager-restart
    ../../modules/nixos/rgb-off.nix
    ../../modules/nixos/cooler-lcd
    ../../modules/nixos/ipv4-forward.nix
    ../../modules/nixos/container-slots.nix
    ../../modules/nixos/agent-slots.nix
    ../../modules/nixos/mullvad-egress
    ../../modules/nixos/web-bench-mullvad.nix
    ../../modules/nixos/zfs-ephemeral-tmp.nix
    ../../modules/nixos/zfs-arc-max.nix
    ../../modules/nixos/per-user-tmp
    ../../modules/nixos/agent-mail
    # Pooled Claude subscription gateway, https://teamclaude.davhau.com/.
    ../../modules/nixos/teamclaude-gateway
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

  # The ARC had grown to ~19 GiB of the 64 GiB, more than any slot.
  hyper.zfsArcMax = 8 * 1024 * 1024 * 1024;

  # Room the kernel reclaims from last; see slots.asof.memoryLow below.
  # MemoryLow= protects only as far as every ancestor cgroup has it.
  systemd.slices.machine.sliceConfig.MemoryLow = "6G";

  # /tmp on disk (zroot/root/nobackup/tmp, ./disko.nix), emptied at boot,
  # and a private /tmp and /var/tmp per user: users with ssh access must
  # not see each other's temp files.
  hyper.zfsEphemeralTmp.dataset = "zroot/root/nobackup/tmp";
  hyper.perUserTmp.enable = true;

  # Boot unlock without a passphrase while vit is up
  # (../../modules/nixos/tang-client.nix), and som serves vit in turn. bam
  # stays out: its root is not encrypted, so its Tang keys would leave with
  # it.
  hyper.tangClient = {
    servers = [ "vit" ];
    interface = "enp6s0";
  };
  hyper.tangServer = {
    enable = true;
    interface = "br0";
    address = "fe80::7a6e:1";
    networkdUnit = "40-br0";
  };

  # `clan-unlock som`: the initrd at a fixed link-local address, through vit.
  hyper.unlockTarget = {
    address = "fe80::7a6e:1";
    initrdNetwork = "40-enp6s0";
    lanInterface = "br0";
    via = "vit";
  };

  # No wifi on this desktop: it sits on the LAN cable. The AX210 stays
  # unbound (no wlan0, no supplicant, no initrd PSK); nixos-facter's
  # wlan0 network unit just never matches.
  boot.blacklistedKernelModules = [ "iwlwifi" ];

  # Fans/water block (on the board's ARGB headers) dark; RAM LEDs on.
  hyper.rgbOff.colorfulArgb = true;
  hyper.rgbOff.dramMode = "rainbow";

  # Thermalright AIO LCD (0416:5302); its port is cut 22:00-07:00
  # (../../modules/nixos/cooler-lcd).
  hyper.coolerLcd.usbPort = "1-0:1.0/usb1-port8";

  # Public hermes dashboards, one per agent in ./hermes-agents.nix:
  # https://<agent>.davhau.fyi/ with hermes' own pocket-id login, and their
  # serve ports at https://<port>.<agent>.davhau.fyi/
  # (../../modules/nixos/hermes-dashboard-public.nix,
  # ../../modules/nixos/hermes-agents-serve.nix). davhau.fyi is the agents'
  # site, apart from davhau.com. *.davhau.fyi and *.<agent>.davhau.fyi A ->
  # sgp (forwarded here), AAAA -> the token address below, kept by
  # porkbun-records. https://hermes.davhau.com/ (oauth2-proxy) redirects the
  # signed-in account to its dashboard, /app lists its addresses for Hermes
  # Mobile; the mail owner page sits next to it. The old names
  # <agent>.agents.davhau.com and <port>.hermes.davhau.com only answer 301
  # to the new ones during the transition (`legacy`).
  hyper.hermesDashboard = {
    host = "hermes.davhau.com";
    agentDomain = (import ./hermes-dashboards.nix).domain;
    publicIPv4 = "38.89.142.76";
    legacy = {
      agentDomain = "agents.davhau.com";
      servePorts = true;
    };
  };

  # Receive-only mail for every agent in ./hermes-agents.nix at
  # <agent>@agents.davhau.com (../../modules/nixos/agent-mail, DNS records
  # listed there). Inbound SMTP arrives only as IPv4 forwarded from sgp, on
  # the tunnel interface of ../../modules/nixos/ipv4-forward.nix; 25 is open
  # there and nowhere else.
  hyper.agentMail = {
    enable = true;
    smtpInterfaces = [ "wg-v4fwd" ];
  };

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
  # slot as `slots.<name> = { id; mode; }`; ids 4..14 are the agent slots
  # below (slotIds).
  hyper.containerSlots = {
    enable = true;
    uplink = "enp6s0";
    uplinkMac = "a4:0c:66:1b:29:f1";
    # Default root key in the bootstrap system every slot starts with
    # (agent slots take their agent's key instead).
    deployKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU agent@amy"
    ];
    # The borrowed public IPv4 (../../modules/nixos/ipv4-forward.nix).
    publicIPv4Interface = "wg-v4fwd";

    # The isolated (agent) slots' own connections leave through Mullvad,
    # like the agents' own traffic (hyper.mullvadEgress below; 51830 is its
    # table, ../../modules/nixos/mullvad-egress/egress.nix), never the home
    # uplink. No tunnel, no egress. Inbound to the slots is unchanged.
    isolatedEgress = {
      interface = "wg-mullvad";
      table = 51830;
    };
    # The routers' WAN side, which "never the LAN" does not cover by itself
    # (seen from som, 2026-10-17): the Beryl relays v6 (its addresses are in
    # the LAN /64, its ULA fdea:fc9f:d6a5::1, WAN v4 192.168.1.x), the AIS
    # ZTE is 192.168.1.1 and 2405:9800:b901:94e3:ea81:75ff:fec9:619c on the
    # LAN side, CGNAT 100.67.x on the WAN side: all in the always-dropped
    # ranges. Its WAN v6 is not visible from the LAN; its upstream hop is
    # 2405:9800:b014::1, so that link's /64 is the likely home of it.
    # Through Mullvad these would arrive from the internet anyway.
    isolatedBlockedDestinations = [ "2405:9800:b014::/64" ];

    # v6 2405:9800:b901:94e3::5107:1, v4 from the LAN's DHCP.
    slots.asof = {
      id = 1;
      mode = "lan";
      # asofd and trader-live inside reserve memory with MemoryLow=; that
      # only holds if this unit and machine.slice (above) reserve it too.
      memoryLow = "6G";
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

    # Agents working on asof; root takes the agent@amy key above.
    # v6 2405:9800:b901:94e3::5107:3, v4 from the LAN's DHCP.
    slots.asof-agents = {
      id = 3;
      mode = "lan";
    };
  };

  # One isolated slot per hermes agent (../../modules/nixos/agent-slots.nix),
  # off until the agent starts it. The ids are fixed: addresses, ports and
  # the router rules derive from them, so never renumber or reuse one; a new
  # agent takes the next free id. The deploy key is the agent's own clan
  # key (hermes-agent-ssh-<name>, ../../modules/nixos/hermes-agents.nix), the
  # one vit's GPU accounts also trust. Hostname slot.<agent>.davhau.fyi, on
  # the agents' site; the old <agent>.slots.davhau.com only redirects there
  # during the transition. The other container slots above have no public
  # hostname, so nothing of theirs moves.
  hyper.agentSlots =
    let
      slotIds = {
        dave-hermes = 4;
        adam = 5;
        chris = 6;
        domi = 7;
        egg = 8;
        j = 9;
        momentum = 10;
        pinpox = 11;
        rti = 12;
        stefan = 13;
        willi = 14;
        b3x = 15;
        joe = 16;
      };
      key = name: config.clan.core.vars.generators."hermes-agent-ssh-${name}".files;
    in
    {
      domain = (import ./hermes-dashboards.nix).domain;
      legacyDomain = "slots.davhau.com";
      publicIPv4 = "38.89.142.76";
      agents = lib.genAttrs agents (name: {
        id =
          slotIds.${name}
            or (throw "machines/som: hermes agent ${name} has no slot id; add it to slotIds");
        deployKey = (key name)."key.pub".value;
        identityFile = (key name).key.path;
      });
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

  # These users reach the internet only through Mullvad in Singapore, and
  # these units of theirs also resolve through it.
  hyper.mullvadEgress = {
    users = [
      "web-bench-mullvad"
    ]
    ++ lib.optionals (mullvadStage >= 2) ([ "searx" ] ++ agents);
    dns.services = lib.optionals (mullvadStage >= 2) (
      [ "searx" ] ++ lib.concatMap hermesLib.agentUnits agents
    );
    # The LAN's public /64: on-link, and inference.p0.contact lives on it
    # (../../modules/nixos/virtualisation.nix). p0 is our own authenticated
    # API on the LAN, so it stays direct: no detour, no exit-IP concerns.
    directPrefixes = [ "2405:9800:b901:94e3::/64" ];
  };
  # searx's uid as allocated on som, pinned so the uid rules can name it.
  users.users.searx.uid = lib.mkIf (mullvadStage >= 2) 986;

  system.stateVersion = "25.11";
}
