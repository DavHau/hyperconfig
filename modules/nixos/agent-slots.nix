# Agent slots: every agent in `hyper.agentSlots.agents` gets its own
# container slot (./container-slots.nix), named after the agent, in
# isolated mode: the internet only, never the LAN, this host or another
# slot. The agent deploys whatever NixOS system it likes into it, switches
# it on and off, and resets it when it locked itself out. The how-to the
# agents read is ./agent-slots-skill/SKILL.md; `slot info` prints the
# per-agent facts. What the slot itself connects to leaves the way the
# host's isolatedEgress says (on som: Mullvad, like the agents' own
# traffic, machines/som/configuration.nix), never the home uplink.
#
# Only the agent gets in by ssh. The slot's bootstrap sshd lets in root
# with the agent's key alone (the slot's deployKeys, bind-mounted read-only
# by ./container-slots.nix), not the host-wide deploy keys. A second lock
# in front of it: from this host, ssh on any slot address, every port of
# the internal v4 10.43.<id>.2 and anything else over the veth answer only
# the agent's uid, root and nginx (the proxies below) (the `agent-slots`
# nft table; like the owner-only gates of hyperhermes' core firewall, but
# nft's own socket-uid match). Otherwise another agent could reach the
# slot from 10.43.<id>.1, the address the proxies use, and pass for them;
# a slot may trust X-Real-IP (or the last X-Forwarded-For entry) from that
# address only. Services an agent publishes on the slot's public /128 are
# for everyone, the other agents on this host included: they reach every
# port but 22 there, as the internet does, from this host's uplink
# address, never from the veth's host side. Everyone on the internet
# reaches the slot's public /128 once the routers allow it; there the key
# is the only lock for ssh. Root here keeps the admin path
# (machinectl shell <agent>, the reset units below). The agent's ssh pins
# the slot's host key (one per slot, kept by this host across resets and
# deploys, ./container-slots.nix); a stopped slot's addresses are
# unreachable rather than handed to the LAN, and a guest that drops the
# key is refused, not trusted.
#
# On and off: the containers do not start at boot (autoStart off). Root-run
# units do the work: agent-slot-{start,stop,reset,reset-hard}@<agent>
# record the desired state in /var/lib/agent-slots/<agent>/state and act on
# container@<agent>; agent-slots-restore starts at boot every slot whose
# state is on, so a reboot returns each slot to where its agent left it.
# The agents reach those units through one socket, /run/agent-slot-ctl.sock:
# each connection runs a root service (Accept=yes) that reads one verb, takes
# the caller's uid from the socket (SO_PEERCRED, i.e. the kernel's word) and
# starts agent-slot-<verb>@<that agent> itself, with the default job mode.
# Not polkit: polkit sees the unit and the verb, not the job mode, so an
# agent allowed to start its own unit could start it with --job-mode=flush
# and cancel every other queued job on the host. Each action is
# rate-limited (6 runs per 10 minutes) and logs what it did to the journal.
# `slot` (on the agents' PATH) talks to the socket.
#
# Reset: stop, drop the slot's system profile (every generation), so the
# next start reseeds the bootstrap system with the agent's key, then restore
# the previous on/off state. `reset-hard` also wipes the slot's whole root,
# its /tmp, its gc roots and every profile (/root, /var: everything the
# guest wrote); only the host-side state stays (desired state, the key file
# and the host key the host provides).
#
# Addresses (id from the fixed table on the host; never renumber: router
# rules and ports derive from it):
#   v6       <ipv6Prefix>::5107:<id hex>, public, direct for inbound (router
#            allow rules as in ./container-slots.nix); outbound NAT'd to the
#            egress link's address
#   v4       10.43.<id>.2, this host only; outbound NAT'd the same way
#   hostname slot.<agent>.<domain> (on som slot.<agent>.davhau.fyi, the
#            agents' site, below the agent's name like its serve ports):
#            AAAA the v6, A the shared public IPv4, both kept at porkbun by
#            this host (./porkbun-records, hourly and at boot; nobody edits
#            them by hand). A new agent's records appear
#            after the deploy at the next sync (or `systemctl start
#            porkbun-records`); a removed agent's are deleted. The AAAA
#            takes the /64 on the bridge at sync time and warns when it is
#            no longer ipv6Prefix (then redeploy with the new prefix).
#   ports    TCP portBase + 10 * id .. +9 on the public IPv4, DNATed to the
#            same port in the slot (./container-slots.nix publicIPv4Ports),
#            client address kept. TCP only: IPv6 already gives the slot every
#            UDP port, and v4 UDP has no use here that would justify keeping
#            per-port conntrack state for it on both ends of the tunnel.
#            portBase 14000 keeps the whole id range (14010..16549) clear of
#            every port som or sgp listens on (sgp: 21, 22, 51820/udp; som:
#            22, 80, 443, 655, 5000-9993, 11434-12345, 19999-31055 loopback,
#            ...) and below the kernel's ephemeral range (32768+).
#
# The shared public IPv4 on 80/443 (it arrives on publicIPv4Interface from
# sgp, ./ipv4-forward.nix): by hostname, slot.<agent>.<domain> goes to that
# agent's slot, everything else stays with this host's nginx.
#   80   nginx proxies a vhost per agent to 10.43.<id>.2:80 (Host kept,
#        websockets, no buffering), so ACME HTTP-01 works inside the slot.
#        The slot sees this host as the peer, the client in X-Forwarded-For.
#   443  redirected (nft, only on publicIPv4Interface) to an nginx stream
#        server that reads the SNI without terminating TLS (ssl_preread).
#        slot.<agent>.<domain> is passed through to 10.43.<id>.2:443, so TLS ends
#        in the slot; the slot sees this host (10.43.<id>.1) as the peer and
#        gets no PROXY header: plain TLS servers work unchanged, and the v4
#        client address of an https connection is not visible in the slot
#        (v6 clients arrive directly with their own address). Everything
#        else goes to this host's own nginx https servers through an extra
#        PROXY-protocol listener on a unix socket (defaultListen), and
#        real_ip restores the client address there, so this host's sites
#        keep seeing it as before. nginx stream proxy_protocol is one switch
#        per server, so slot traffic takes a second hop that accepts and
#        drops the PROXY header before dialling the slot.
#   IPv6 is untouched: the AAAA points at the slot, not at this host.
#
# Resources: memoryMax/cpuQuota per slot (defaults below), and all slots
# together in agent-slots.slice (`limits`): som has 60G and uses most of it,
# so eleven slots at 4G each must not all get it. reset-hard also drops the
# slot's gc roots and profiles, which the guest can write through its binds
# and which pin store paths on the shared disk. A slot's nix builds run in
# nix-daemon's cgroup, outside these, but the agents could already run the
# same builds natively; the slot adds no new daemon load class, so this file
# leaves nix-daemon alone. Disk: the slots' roots (/var/lib) and /tmp sit on
# som's shared ZFS datasets without per-slot quotas; per-slot datasets would
# mean moving roots on a 92% full production pool, not done here.
#
# Cookies: a slot serves whatever its agent deploys, so it lives on the
# agents' site (davhau.fyi, hyperhermes' dashboards module), never on
# davhau.com. A page in the slot can set cookies for <agent>.<domain> (its
# own agent's dashboard and serve ports: nothing the agent does not control
# already; logins there are `__Host-` cookies it cannot touch) or for
# <domain> (every agent: the cookie-bombing residual the dashboard module
# names). The slot's hostname also matches the agent's private serve ports'
# OIDC callback pattern (./hermes-agents-serve.nix); a code that lands
# here is useless without that client's secret and PKCE verifier.
#
# Transition (legacyDomain): the old names <agent>.<legacyDomain> (on som
# <agent>.slots.davhau.com) answer 301 to https://slot.<agent>.<domain>/,
# path and query kept, on port 80 as on 443, and reach no slot: this host
# terminates TLS for them (wildcard cert *.<legacyDomain>, porkbun DNS-01)
# instead of passing them through, and their records point at this host (A
# the shared IPv4, AAAA networking.publicIPv6 where the host has one). Drop
# legacyDomain once the old links are gone. Let's Encrypt follows redirects
# in HTTP-01, and the 301 leads into the slot, so the old names answer 404
# under /.well-known/acme-challenge/, and CAA on <legacyDomain> lets Let's
# Encrypt issue below it by DNS-01 only (the porkbun key is root's): the
# agent cannot get a certificate for an old name anymore. The slots still
# hold the certificates they got for their old names before the move,
# valid up to 90 days after their last renewal. A slot can present one
# only on a connection that reaches it, which for the old name no longer
# happens (its A and AAAA lead here, and the SNI router passes only the
# new name through) short of stale DNS or someone on the path; it expires
# unrenewed.
{
  config,
  lib,
  options,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.agentSlots;
  slotsCfg = config.hyper.containerSlots;
  nginxCfg = config.services.nginx;
  inherit (lib) mkOption types;

  portBase = 14000;
  # Internal: where nft sends v4 443, and the two nginx hops behind it.
  # Below 1024: only root may bind it, so no agent takes the shared IPv4's
  # 443 while nginx restarts.
  sniPort = 444;
  httpsSock = "/run/nginx/agent-slots-https.sock";
  hopSock = "/run/nginx/agent-slots-hop.sock";
  stateDir = "/var/lib/agent-slots";

  hex = id: lib.toLower (lib.toHexString id);
  ipv4Of = a: "10.43.${toString a.id}.2";
  ipv6Of = a: "${slotsCfg.ipv6Prefix}::5107:${hex a.id}";
  # Where ./container-slots.nix puts the host side of every isolated slot's
  # veth (hostAddress6 fd43:5107::<id hex>:1, the slot's v6 gateway).
  vethHost6Prefix = "fd43:5107::/64";
  portsOf = a: lib.genList (i: portBase + 10 * a.id + i) 10;
  portRange = a: "${toString (portBase + 10 * a.id)}-${toString (portBase + 10 * a.id + 9)}";
  hostOf = name: "slot.${name}.${cfg.domain}";
  legacyHostOf = name: "${name}.${cfg.legacyDomain}";
  legacyCert = "agent-slots-legacy";
  uidOf = name: config.users.users.${name}.uid;
  nginxUid = config.users.users.${nginxCfg.user}.uid;
  names = lib.attrNames cfg.agents;
  iface = slotsCfg.publicIPv4Interface;

  systemctl = "${config.systemd.package}/bin/systemctl";
  actions = [
    "start"
    "stop"
    "reset"
    "reset-hard"
  ];
  ctlSocket = "/run/agent-slot-ctl.sock";

  ctl = pkgs.writeShellApplication {
    name = "agent-slot-ctl";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gawk
    ];
    text = ''
      action=$1
      name=$2
      case "$name" in
        ${lib.concatStringsSep "|" names}) ;;
        *) echo "agent-slots: no slot named '$name'" >&2; exit 1 ;;
      esac
      dir=${stateDir}/$name
      profiles=/nix/var/nix/profiles/per-container/$name
      install -d -m 0755 ${stateDir} "$dir"
      # start/stop/reset of one slot never interleave
      exec 9>"$dir/lock"
      flock 9
      desired() { cat "$dir/state" 2>/dev/null || echo off; }
      # durable before acting: a crash right after must not forget it
      record() { echo "$1" >"$dir/state.new"; sync "$dir/state.new"; mv "$dir/state.new" "$dir/state"; sync "$dir"; }
      # Rate limit, here and not StartLimitBurst=: a finished oneshot
      # instance is garbage-collected, and its start counter with it.
      now=$(date +%s)
      recent=0
      if [ -e "$dir/runs" ]; then
        recent=$(awk -v a="$action" -v since=$((now - 600)) '$2 == a && $1 > since' "$dir/runs" | wc -l)
        tail -n 200 "$dir/runs" >"$dir/runs.new" && mv "$dir/runs.new" "$dir/runs"
      fi
      if [ "$recent" -ge 6 ]; then
        echo "slot $name: $action refused, 6 already in the last 10 minutes" >&2
        exit 1
      fi
      echo "$now $action" >>"$dir/runs"
      # A slot that failed to start (a refused root tree, a crashing guest)
      # is restarted by the unit until systemd's start limit stops it; the
      # agent's own start or reset must still go through, and this script
      # has its own rate limit.
      start_slot() {
        ${systemctl} reset-failed "container@$name.service" 2>/dev/null || true
        ${systemctl} start "container@$name.service"
      }
      case "$action" in
        start)
          echo "slot $name: start (desired on)"
          record on
          start_slot
          ;;
        stop)
          echo "slot $name: stop (desired off)"
          record off
          ${systemctl} stop "container@$name.service"
          ;;
        reset | reset-hard)
          prev=$(desired)
          echo "slot $name: $action, then back to $prev"
          ${systemctl} stop "container@$name.service"
          # every generation: the next start seeds the bootstrap system
          rm -f "$profiles/system" "$profiles"/system-*-link
          if [ "$action" = reset-hard ]; then
            rm -rf --one-file-system "/var/lib/nixos-containers/$name"
            if [ -d "/tmp/.slots/$name" ]; then
              find "/tmp/.slots/$name" -mindepth 1 -xdev -delete
            fi
            # The guest's gc roots and every profile it made pin store
            # paths on the shared disk; the start script recreates both
            # directories empty.
            rm -rf --one-file-system "/nix/var/nix/gcroots/per-container/$name" "$profiles"
          fi
          if [ "$prev" = on ]; then
            start_slot
          fi
          ;;
        *) echo "agent-slots: unknown action '$action'" >&2; exit 1 ;;
      esac
    '';
  };

  restore = pkgs.writeShellScript "agent-slots-restore" ''
    for name in ${lib.escapeShellArgs names}; do
      if [ "$(cat ${stateDir}/$name/state 2>/dev/null)" = on ]; then
        echo "slot $name: on before, starting"
        ${systemctl} start --no-block "container@$name.service"
      fi
    done
  '';

  # One connection on the control socket: the caller's uid (from the
  # kernel, SO_PEERCRED) picks the slot, the one line it sends picks the
  # action, and this root service starts the control unit itself. Callers
  # never talk to systemd, so they choose nothing but the verb.
  accept = pkgs.writers.writePython3 "agent-slot-ctl-accept" { flakeIgnore = [ "E501" ]; } ''
    import socket
    import struct
    import subprocess
    import sys

    SLOTS = {${lib.concatMapStringsSep ", " (name: "${toString (uidOf name)}: \"${name}\"") names}}
    ACTIONS = {${lib.concatMapStringsSep ", " (a: "\"${a}\"") actions}}

    conn = socket.socket(fileno=0)
    _pid, uid, _gid = struct.unpack(
        "3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))


    def reply(msg):
        try:
            conn.sendall((msg + "\n").encode())
        except OSError:
            pass


    conn.settimeout(10)
    data = b""
    try:
        while b"\n" not in data and len(data) < 64:
            chunk = conn.recv(64)
            if not chunk:
                break
            data += chunk
    except OSError:
        pass
    verb = data.split(b"\n", 1)[0].decode("ascii", "replace").strip()

    name = SLOTS.get(uid)
    if name is None:
        print(f"uid {uid}: has no slot, refused")
        reply("refused: this account has no slot")
        sys.exit(1)
    if verb not in ACTIONS:
        print(f"{name}: unknown action {verb!r}, refused")
        reply("refused: unknown action")
        sys.exit(1)
    print(f"{name}: {verb}")
    rc = subprocess.run(["${systemctl}", "start", f"agent-slot-{verb}@{name}.service"]).returncode
    reply("ok" if rc == 0 else "failed")
    sys.exit(0 if rc == 0 else 1)
  '';

  infoArm =
    name: a:
    let
      ports = portRange a;
    in
    ''
      ${name})
        v4=${ipv4Of a}
        v6=${ipv6Of a}
        host=${hostOf name}
        ports=${ports}
        ;;
    '';

  slotCli = pkgs.writeShellApplication {
    name = "slot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.socat
    ];
    text = ''
      me=$(id -un)
      case "$me" in
        ${lib.concatStrings (lib.mapAttrsToList infoArm cfg.agents)}
        *) echo "slot: account $me has no container slot" >&2; exit 1 ;;
      esac

      usage() {
        echo "usage: slot status|start|stop|reset [--hard]|info" >&2
        exit 2
      }

      status() {
        desired=$(cat ${stateDir}/"$me"/state 2>/dev/null || echo off)
        actual=$(${systemctl} is-active "container@$me.service" || true)
        echo "slot $me: desired $desired, container $actual"
      }

      run() {
        # -t: wait for the answer after sending (a start takes ~30 s)
        reply=$(printf '%s\n' "$1" | socat -t 900 -T 900 - UNIX-CONNECT:${ctlSocket}) || reply=""
        if [ "$reply" != ok ]; then
          echo "slot: $1 failed''${reply:+ ($reply)} (at most 6 runs per 10 minutes each)" >&2
          status
          exit 1
        fi
        status
      }

      info() {
        cat <<EOF
      slot:      $me (off by default; slot start|stop|reset [--hard]|status)
      ssh:       root@$v4 (from this host; only you and root get through)
                 root@[$v6] (anywhere)
      ipv6:      $v6 (public, all ports; the slot's firewall decides;
                 other agents here reach all but 22, like the internet)
      ipv4:      $v4 (this host only, you alone); public ${cfg.publicIPv4} shared
      hostname:  $host (A ${cfg.publicIPv4}, AAAA $v6)
      http(s):   $host on ${cfg.publicIPv4} ports 80/443 reaches the slot's
                 80/443 (TLS passes through by SNI; ends in the slot)
      tcp ports: ${cfg.publicIPv4}:$ports -> the same ports in the slot
      deploy:    nixos-rebuild switch --flake .#<cfg> \\
                   --target-host root@$v4 --build-host root@$v4
      EOF
      }

      case "''${1:-}" in
        status) status ;;
        start) run start ;;
        stop) run stop ;;
        reset)
          case "''${2:-}" in
            "") run reset ;;
            --hard) run reset-hard ;;
            *) usage ;;
          esac
          ;;
        info) info ;;
        *) usage ;;
      esac
    '';
  };

  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "container-slot";
    src = lib.fileset.toSource {
      root = ./agent-slots-skill;
      fileset = ./agent-slots-skill/SKILL.md;
    };
  };

  agentOptions = {
    options = {
      id = mkOption {
        type = types.ints.between 1 254;
        description = "The slot id (./container-slots.nix); fixed forever, addresses and ports derive from it.";
      };
      deployKey = mkOption {
        type = types.str;
        description = "The agent's ssh public key; the only key the slot's bootstrap sshd admits.";
      };
      identityFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Private half of deployKey, readable by the agent; ssh picks it for the slot's addresses.";
      };
      memoryMax = mkOption {
        type = types.str;
        default = "4G";
        description = "MemoryMax= of the slot (its processes; not its nix builds).";
      };
      cpuQuota = mkOption {
        type = types.str;
        default = "400%";
        description = "CPUQuota= of the slot.";
      };
    };
  };
in
{
  imports = [ ./porkbun-records ];

  options.hyper.agentSlots = {
    agents = mkOption {
      type = types.attrsOf (types.submodule agentOptions);
      default = { };
      description = "One isolated container slot per agent account, named after it.";
    };
    domain = mkOption {
      type = types.str;
      example = "davhau.fyi";
      description = "The agents' domain; each slot's hostname is slot.<agent>.<domain>.";
    };
    legacyDomain = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "slots.davhau.com";
      description = "Transition: the slots' old parent domain. https://<agent>.<legacyDomain>/ answers 301 to the slot's hostname from this host's nginx, nothing else.";
    };
    publicIPv4 = mkOption {
      type = types.str;
      example = "38.89.142.76";
      description = "The shared public IPv4 arriving on publicIPv4Interface (shown to the agents).";
    };
    limits = {
      memoryHigh = mkOption {
        type = types.str;
        default = "10G";
        description = "MemoryHigh= of agent-slots.slice: all slots together get throttled and reclaimed above this.";
      };
      memoryMax = mkOption {
        type = types.str;
        default = "12G";
        description = "MemoryMax= of agent-slots.slice: all slots together.";
      };
      tasksMax = mkOption {
        type = types.ints.positive;
        default = 8192;
        description = "TasksMax= of agent-slots.slice (each slot gets a quarter of it).";
      };
      cpuWeight = mkOption {
        type = types.ints.between 1 10000;
        default = 20;
        description = "CPUWeight= of agent-slots.slice (the host's own services default to 100).";
      };
      ioWeight = mkOption {
        type = types.ints.between 1 10000;
        default = 20;
        description = "IOWeight= of agent-slots.slice (only where the I/O scheduler honours it; ZFS mostly does not).";
      };
    };
  };

  config = lib.mkIf (cfg.agents != { }) {
    assertions = [
      {
        assertion = iface != null;
        message = "hyper.agentSlots needs hyper.containerSlots.publicIPv4Interface";
      }
    ]
    ++ map (name: {
      assertion = config.users.users ? ${name} && uidOf name != null;
      message = "hyper.agentSlots.agents.${name}: needs an account with a pinned uid (the ssh gate matches it)";
    }) names;

    hyper.containerSlots.slots = lib.mapAttrs (_: a: {
      inherit (a) id memoryMax cpuQuota;
      mode = "isolated";
      autoStart = false;
      deployKeys = [ a.deployKey ];
      publicIPv4Ports = portsOf a;
    }) cfg.agents;

    # --- DNS: slot.<agent>.<domain> A and AAAA (./porkbun-records) --------
    # Each name needs its own A: a wildcard A does not answer a name that
    # has records of its own (the AAAA); the agent's *.<agent>.<domain>
    # (./hermes-agents-serve.nix) does not apply to it either. The AAAA
    # follows the /64 on the bridge at sync time, not ipv6Prefix: the
    # slot's configured address (ipv6Of) is dead anyway once the router
    # advertises another /64, because the router routes only its current
    # prefix to the LAN. The record then already names the address the slot
    # gets with the redeploy the warning asks for (ipv6Prefix set to the new
    # /64), instead of staying wrong after it until the next sync.
    hyper.porkbunRecords.records =
      lib.mapAttrs' (
        name: a:
        lib.nameValuePair (hostOf name) {
          A = cfg.publicIPv4;
          AAAA.ipv6OnLink = {
            interface = slotsCfg.bridge;
            suffix = "::5107:${hex a.id}";
            expectedPrefix = slotsCfg.ipv6Prefix;
          };
        }
      ) cfg.agents
      # The old names point at this host, which only redirects them; CAA
      # (the header).
      // lib.optionalAttrs (cfg.legacyDomain != null) (
        lib.genAttrs (map legacyHostOf names) (
          _:
          {
            A = cfg.publicIPv4;
          }
          // lib.optionalAttrs (options.networking ? publicIPv6) {
            AAAA.ipv6OnLink = {
              inherit (config.networking.publicIPv6) interface;
              suffix = config.networking.publicIPv6.token;
            };
          }
        )
        // {
          ${cfg.legacyDomain}.CAA = ''0 issue "letsencrypt.org; validationmethods=dns-01"'';
        }
      );

    # The old names' certificate (the header). Shared var, same definition
    # as ./dyndns-porkbun.nix; only DNS-01 reads it here.
    clan.core.vars.generators.porkbun = lib.mkIf (cfg.legacyDomain != null) {
      share = true;
      prompts.apikey.type = "hidden";
      prompts.apikey.persist = true;
      prompts.secretkey.type = "hidden";
      prompts.secretkey.persist = true;
    };
    security.acme.certs = lib.mkIf (cfg.legacyDomain != null) {
      ${legacyCert} = {
        domain = "*.${cfg.legacyDomain}";
        dnsProvider = "porkbun";
        # Not an enableACME cert, so the nginx module leaves the group alone.
        group = "nginx";
        credentialFiles = {
          PORKBUN_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.apikey.path;
          PORKBUN_SECRET_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.secretkey.path;
        };
        # As the dashboards' cert (machines/som exposure.acme).
        dnsResolver = "1.1.1.1:53";
      };
    };

    # --- resources: all slots together ------------------------------------
    systemd.slices.agent-slots = {
      description = "Agent container slots";
      sliceConfig = {
        MemoryAccounting = true;
        MemoryHigh = cfg.limits.memoryHigh;
        MemoryMax = cfg.limits.memoryMax;
        TasksAccounting = true;
        TasksMax = cfg.limits.tasksMax;
        CPUWeight = cfg.limits.cpuWeight;
        IOWeight = cfg.limits.ioWeight;
      };
    };

    # --- on, off, reset ---------------------------------------------------
    systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

    systemd.services = lib.mkMerge [
      (lib.genAttrs (map (name: "container@${name}") names) (_: {
        # nixpkgs puts every container in machine.slice
        serviceConfig.Slice = lib.mkForce "agent-slots.slice";
        serviceConfig.TasksMax = cfg.limits.tasksMax / 4;
      }))
      (lib.listToAttrs (
        map (
          action:
          lib.nameValuePair "agent-slot-${action}@" {
            description = "Agent slot %i: ${action}";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe ctl} ${action} %i";
              TimeoutStartSec = "5min";
            };
          }
        ) actions
      ))
      {
        agent-slots-restore = {
          description = "Start the agent slots that were on";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = restore;
          };
        };
      }
      {
        "agent-slot-ctl@" = {
          description = "Agent slot control request from %i";
          serviceConfig = {
            ExecStart = accept;
            StandardInput = "socket";
            StandardOutput = "journal";
            StandardError = "journal";
            RuntimeMaxSec = "15min";
          };
        };
      }
    ];

    # Every agent may connect; the service decides by the caller's uid.
    systemd.sockets.agent-slot-ctl = {
      description = "Agent slot control socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = ctlSocket;
        SocketMode = "0666";
        Accept = true;
        MaxConnections = 32;
        MaxConnectionsPerSource = 4;
      };
    };

    # --- ssh: the agent's key, and only the agent's uid -------------------
    # The slot's host key is the one this host generated for it and keeps
    # (./container-slots.nix), so it is pinned: a stopped slot's addresses
    # are unreachable, and anything else answering on them is refused.
    programs.ssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList (
        name: a:
        lib.optionalString (a.identityFile != null) ''
          Match host ${ipv4Of a},${ipv6Of a} localuser ${name}
            IdentityFile ${a.identityFile}
            IdentitiesOnly yes
            StrictHostKeyChecking yes
            UserKnownHostsFile ${slotsCfg.hostKeysDir}/${name}/known_hosts
        ''
      ) cfg.agents
    );

    networking.nftables.enable = true;
    networking.nftables.tables.agent-slots = {
      family = "inet";
      content = ''
        # this host -> a slot. The owning agent, root and nginx (the :80
        # vhost and the SNI hop dial the slot from 10.43.<id>.1) reach
        # everything. Every other uid (the other agents) gets what the
        # internet gets: the public /128, every port but ssh. ssh on any
        # address, the internal v4 and whatever else leaves over the veth
        # (link-local) stay the owner's. The internal v4 is the proxies'
        # path: a slot may trust 10.43.<id>.1 as its proxy hop only because
        # nobody else reaches it from there.
        #
        # Every packet, not only a flow's first: two UDP sockets that both
        # set SO_REUSEADDR share a local port whatever their uid, so another
        # agent's datagrams could otherwise ride the owner's established
        # flow. Packets without a local socket (forwarded, the kernel's own:
        # ND, TCP resets) never match skuid and pass; this host serves
        # nothing to the slots (container-slots' input chain), so no reply
        # of one of its sockets is caught here either.
        chain output {
          type filter hook output priority filter; policy accept;
          jump slot-gate
        }
        chain slot-gate {
          ${lib.concatStrings (
            lib.mapAttrsToList (
              name: a:
              let
                ok = "{ 0, ${toString (uidOf name)}, ${toString nginxUid} }";
                other = "meta skuid != ${ok}";
              in
              ''
                ip daddr ${ipv4Of a} ${other} jump refuse
                oifname "ve-${name}" meta nfproto ipv4 ${other} jump refuse
                oifname "ve-${name}" ip6 daddr != ${ipv6Of a} ${other} jump refuse
                ip6 daddr ${ipv6Of a} ${other} meta l4proto { tcp, udp } th dport 22 jump refuse
                # From one of this host's own addresses (no IPV6_FREEBIND
                # spoofing), and never from a veth's host side (the slots'
                # v6 gateways fd43:5107::<id>:1, link-local): a slot must be
                # able to tell the host itself from another agent. With the
                # gateway deprecated (./container-slots.nix) the kernel picks
                # the uplink's global address, as for the internet.
                ip6 daddr ${ipv6Of a} ${other} ip6 saddr { fe80::/10, ${vethHost6Prefix} } jump refuse
                ip6 daddr ${ipv6Of a} ${other} fib saddr type != local jump refuse
              ''
            ) cfg.agents
          )}
        }
        chain refuse {
          meta l4proto tcp reject with tcp reset
          reject with icmpx admin-prohibited
        }

        # public IPv4 https -> the SNI router
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          iifname "${iface}" tcp dport 443 redirect to :${toString sniPort}
        }
      '';
    };
    # 80 for the slot vhosts (som opens it everywhere for its own sites
    # anyway), the SNI router for what was 443.
    networking.firewall.interfaces.${iface}.allowedTCPPorts = [
      80
      sniPort
    ];

    # --- the shared public IPv4 on 80/443 ---------------------------------
    services.nginx = {
      enable = true;
      # Every https vhost of this host also listens on the PROXY-protocol
      # socket the SNI router hands non-slot connections to.
      defaultListen =
        map (addr: { inherit addr; }) nginxCfg.defaultListenAddresses
        ++ [
          {
            addr = "unix:${httpsSock}";
            ssl = true;
            proxyProtocol = true;
          }
        ];
      # Only that socket is a unix one, so only its PROXY header is trusted.
      appendHttpConfig = ''
        set_real_ip_from unix:;
        real_ip_header proxy_protocol;
      ''
      + lib.optionalString (cfg.legacyDomain != null) ''
        map $host $agent_slots_legacy {
          default "";
        ${lib.concatMapStrings (name: ''
          "${legacyHostOf name}" ${hostOf name};
        '') names}}
      '';
      streamConfig = ''
        map $ssl_preread_server_name $agent_slots_hop {
          hostnames;
          default unix:${httpsSock};
        ${lib.concatMapStrings (name: ''
          ${hostOf name} unix:${hopSock};
        '') names}
        }
        map $ssl_preread_server_name $agent_slots_backend {
          hostnames;
          # unreachable: the first hop sends only slot names here
          default 127.0.0.1:1;
        ${lib.concatStrings (
          lib.mapAttrsToList (name: a: ''
            ${hostOf name} ${ipv4Of a}:443;
          '') cfg.agents
        )}
        }
        server {
          listen ${toString sniPort};
          ssl_preread on;
          proxy_protocol on;
          proxy_pass $agent_slots_hop;
          proxy_timeout 1h;
        }
        server {
          listen unix:${hopSock} proxy_protocol;
          ssl_preread on;
          proxy_pass $agent_slots_backend;
          proxy_timeout 1h;
        }
      '';
virtualHosts =
        lib.mapAttrs' (
          name: a:
          # nginx makes the first vhost (by attribute name) listening on a port
          # its default server; "slot-*" sorts after this host's own (hermes*),
          # so a request with an unknown Host never lands in a slot.
          lib.nameValuePair "slot-${name}" {
            serverName = hostOf name;
            locations."/" = {
              proxyPass = "http://${ipv4Of a}:80";
              proxyWebsockets = true;
              recommendedProxySettings = true;
              extraConfig = ''
                proxy_buffering off;
                proxy_request_buffering off;
                client_max_body_size 0;
                proxy_read_timeout 1h;
                proxy_send_timeout 1h;
              '';
            };
          }
        ) cfg.agents
        // lib.optionalAttrs (cfg.legacyDomain != null) {
          # Transition only (the header): 301 to the new name, never a
          # slot, on 80 and 443 alike; no ACME challenge answer. Sorts after
          # "slot-*" too.
          slots-legacy = {
            serverName = "*.${cfg.legacyDomain}";
            addSSL = true;
            useACMEHost = legacyCert;
            locations."^~ /.well-known/acme-challenge/".return = "404";
            locations."/".extraConfig = ''
              if ($agent_slots_legacy = "") {
                return 404;
              }
              return 301 https://$agent_slots_legacy$request_uri;
            '';
          };
        };
    };

    # --- what the agents get ----------------------------------------------
    services.hyperhermes.extraPackages = [
      slotCli
      config.system.build.nixos-rebuild
    ];
    services.hyperhermes.skillDirs = [ "${skill}/share/skills" ];
  };
}
