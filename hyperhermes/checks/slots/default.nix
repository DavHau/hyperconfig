# Agent slots (../../modules/slots) on a public-mode host with two agents,
# alice (slot 4) and bob (slot 5), in public exposure mode. `client` plays
# the internet: on vlan 3 it reaches the host's public IPv4 (the link
# services.container-slots.publicIPv4Interface names), on vlan 1 the slots'
# public v6, and on a second link (vlan 2) it is a VPN relay: the stand-in
# for an egress tunnel, which accepts only the tunnel's own source
# addresses, as a relay does. Covered: each agent starts, stops and resets
# only its own slot, through the control socket and never through systemd
# itself (no --job-mode=flush); only its key gets in, only its uid (and
# root, nginx) reaches the slot's ssh, internal v4 and veth, every packet
# of a flow, while the other agent reaches the public v6 like the internet
# does (TCP and UDP, from the uplink address, never the proxy hop or the
# veth's host side), and its ssh pins the slot's host key; the slots reach
# the internet only through the egress link (kill switch), never the host,
# each other or the blocked destinations, while inbound v6 and forwarded
# v4 answer the way they came; a slot cannot steer the host's start script
# through symlinks in its root; stopped slots' addresses are unreachable;
# the desired state survives a reboot; a reset brings back a slot whose
# deploy dropped sshd, a hard reset also drops its gc roots; the slots run
# in agent-slots.slice; the public IPv4 reaches the right slot by port, by
# Host (80) and by SNI (443) under slot.<agent>.<domain>, with the host's
# own https site keeping the client address; the old names
# <agent>.<legacyDomain> only answer this host's 301 to the new one, path
# kept, and never reach a slot; each slot's hostname gets its A and AAAA,
# each old name its A, in exposure.dnsRecords.
#
# The agent registry is a stub (agentsStub): what slots reads of core
# (uid, sshKeyFile, the PATH and skill collection points), without running
# hermes in the VM.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  common = import ./common.nix { inherit pkgs; };
  inherit (common)
    sshKeys
    adminKey
    agentsStub
    responder
    ;

  publicIPv4 = "203.0.113.76";
  clientIPv4 = "203.0.113.10";
  # the LAN (the server's br0)
  serverIPv4 = "192.0.2.2";
  lanIPv4 = "192.0.2.0/24";
  prefix = "2001:db8:1:2";
  # "the internet" over v6, and the stand-ins for the routers' WAN side
  clientIPv6 = "2001:db8:ffff::10";
  routerWanIPv4 = "198.51.100.1";
  routerWanIPv6 = "2001:db8:fffe::1";
  # the egress link (a VPN tunnel): the server's end, the relay's end
  tunnelIPv4 = "10.64.0.2";
  tunnelIPv6 = "fd00:64::2";
  relayIPv4 = "10.64.0.1";
  relayIPv6 = "fd00:64::1";
  egressTable = 51830;
  caa = ''0 issue "letsencrypt.org; validationmethods=dns-01"'';

  # One self-signed certificate for every name in the test.
  cert = pkgs.runCommand "agent-slots-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test \
      -addext "subjectAltName=DNS:server.test,DNS:slot.alice.example.test,DNS:slot.bob.example.test" \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  # A deploy that drops sshd: what locks an agent out of its slot.
  broken =
    (pkgs.nixos {
      boot.isNspawnContainer = true;
      networking.hostName = "";
      system.stateVersion = lib.trivial.release;
    }).toplevel;
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-slots";
  globalTimeout = 1800;

  nodes.client = {
    virtualisation.vlans = [
      1
      2
      3
    ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
    # the host's public IPv4 is on-link on vlan 3
    networking.interfaces.eth3.ipv4.addresses = lib.mkForce [
      {
        address = clientIPv4;
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
      {
        address = clientIPv6;
        prefixLength = 64;
      }
    ];
    # The slots' /64 sits behind the server's proxy NDP on this link.
    networking.interfaces.eth1.ipv6.routes = [
      {
        address = "${prefix}::";
        prefixLength = 64;
      }
    ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
      {
        address = relayIPv4;
        prefixLength = 24;
      }
      {
        address = routerWanIPv4;
        prefixLength = 32;
      }
    ];
    networking.interfaces.eth2.ipv6.addresses = lib.mkForce [
      {
        address = relayIPv6;
        prefixLength = 64;
      }
      {
        address = routerWanIPv6;
        prefixLength = 128;
      }
    ];
    networking.firewall.enable = false;
    # The relay end: only the tunnel's own addresses get in, so anything
    # the server sends down the tunnel unmasqueraded (a reply to an inbound
    # connection taking the wrong way) is lost, as it would be at Mullvad.
    networking.nftables.enable = true;
    networking.nftables.tables.relay = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy accept;
          iifname "eth2" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } accept
          iifname "eth2" ip saddr != ${tunnelIPv4} drop
          iifname "eth2" ip6 saddr != ${tunnelIPv6} drop
        }
      '';
    };
    # "the internet" for the slots' outbound check
    systemd.services.web = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080";
    };
    # tells each caller the address it came from
    systemd.services.peer4 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:8081,fork,reuseaddr EXEC:'${responder} client'";
    };
    systemd.services.peer6 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:8081,ipv6only=1,fork,reuseaddr EXEC:'${responder} client'";
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  nodes.server =
    { config, ... }:
    {
      imports = [
        agentsStub
        common.slotHost
        self.nixosModules.exposure
        self.nixosModules.slots
      ];
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      virtualisation.vlans = [
        1
        2
        3
      ];

      # The public IPv4, on a link of its own (a real deployment may get it
      # through a tunnel from another host).
      networking.interfaces.eth3.ipv4.addresses = lib.mkForce [
        {
          address = publicIPv4;
          prefixLength = 24;
        }
      ];

      # The egress link, as a VPN tunnel would be set up: its own table
      # with default routes, loose reverse-path checks.
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = tunnelIPv4;
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv6.addresses = lib.mkForce [
        {
          address = tunnelIPv6;
          prefixLength = 64;
        }
      ];
      systemd.network.networks."40-eth2".routes = [
        {
          Gateway = relayIPv4;
          Table = egressTable;
        }
        {
          Gateway = relayIPv6;
          Table = egressTable;
        }
      ];
      boot.kernel.sysctl."net.ipv4.conf.eth2.rp_filter" = 2;
      networking.firewall.extraReversePathFilterRules = ''
        iifname "eth2" accept
      '';
      # isolatedEgress needs a loose rpfilter.
      networking.firewall.checkReversePath = "loose";

      # The uplink becomes a port of br0, which carries the address.
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      systemd.network.networks."40-br0".address = [
        "${serverIPv4}/24"
        "${prefix}::2/64"
      ];
      # the v6 "internet" client, on-link here (it reaches the slots by NDP)
      systemd.network.networks."40-br0".routes = [ { Destination = "2001:db8:ffff::/64"; } ];
      services.container-slots = {
        enable = true;
        uplink = "eth1";
        uplinkMac = common.uplinkMacOf config;
        inherit lanIPv4;
        ipv6Prefix = prefix;
        deployKeys = [ adminKey ];
        publicIPv4Interface = "eth3";
        isolatedEgress = {
          interface = "eth2";
          table = egressTable;
        };
        isolatedBlockedDestinations = [
          routerWanIPv4
          routerWanIPv6
        ];
      };

      services.hyperhermes = {
        exposure = {
          enable = true;
          mode = "public";
          domain = "example.test";
          inherit publicIPv4;
          # No ACME server here (defaults.server below): the self-signed
          # placeholders stay and the renewals fail fast.
          acme = {
            dnsProvider = "exec";
            email = "test@example.org";
            inherit caa;
          };
        };
        slots.legacyDomain = "slots.test";
        agents = lib.mapAttrs (name: id: {
          uid = config.users.users.${name}.uid;
          sshKeyFile = "/etc/agent-keys/${name}";
          slot = {
            enable = true;
            inherit id;
            deployKey = sshKeys.${name}.pub;
          };
        }) { alice = 4; bob = 5; };
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
      users.users.bob = {
        isNormalUser = true;
        uid = 1001;
      };
      environment.etc =
        lib.mapAttrs' (
          name: k:
          lib.nameValuePair "agent-keys/${name}" {
            text = k.priv;
            mode = "0600";
            user = name;
          }
        ) sshKeys;

      # This host's own https site (as a deployment's own site); it sorts
      # before the slot vhosts, as a deployment's own do.
      services.nginx.virtualHosts.host-site = {
        serverName = "server.test";
        forceSSL = true;
        sslCertificate = "${cert}/cert.pem";
        sslCertificateKey = "${cert}/key.pem";
        locations."/".return = "200 'server $remote_addr\\n'";
        extraConfig = "default_type text/plain;";
      };
      security.acme.defaults.server = "https://127.0.0.1:1/directory";

      system.extraDependencies = [ broken ];
      # the agents' tools (hyperhermes puts them on the agents' PATH;
      # here system-wide, so runuser finds them)
      environment.systemPackages = config.services.hyperhermes.extraPackages ++ [
        pkgs.curl
        pkgs.netcat-openbsd
      ];
    };

  testScript =
    { nodes, ... }:
    ''
    import ipaddress
    import json

    def in_slot(name):
        return f"${pkgs.util-linux}/bin/nsenter -t $(machinectl show {name} -p Leader --value) -a "

    def serve(name, unit, port, tag, tls=False, v6=False):
        listen = (f"OPENSSL-LISTEN:{port},cert=${cert}/cert.pem,key=${cert}/key.pem,verify=0" if tls
                  else f"TCP6-LISTEN:{port},ipv6only=1" if v6
                  else f"TCP-LISTEN:{port}")
        server.succeed(f"systemd-run --unit={unit} {in_slot(name)} ${pkgs.socat}/bin/socat {listen},fork,reuseaddr EXEC:'${responder} {tag}'")

    # the peer a responder reports, v6 in its compressed form
    def peer(out):
        return str(ipaddress.ip_address(out.split("peer=", 1)[1].split()[0].strip("[]")))

    ssh_as = lambda user, addr, cmd="true": f"runuser -u {user} -- ssh -o BatchMode=yes -o ConnectTimeout=5 root@{addr} {cmd}"
    ssh_key = lambda key, addr: f"ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i /etc/agent-keys/{key} root@{addr} true"
    alice4, bob4 = "10.43.4.2", "10.43.5.2"
    alice6, bob6 = "${prefix}::5107:4", "${prefix}::5107:5"

    start_all()
    server.wait_for_unit("multi-user.target")
    server.wait_for_unit("nginx.service")
    client.wait_for_unit("web.service")
    server.wait_until_succeeds("ping -c1 -W1 ${clientIPv4}", timeout=60)

    with subtest("slots exist but are off by default"):
        server.succeed("systemctl cat container@alice.service >/dev/null")
        server.fail("systemctl is-active container@alice.service")
        assert "desired off" in server.succeed("runuser -u alice -- slot status")

    with subtest("an agent controls its own slot only"):
        server.succeed("runuser -u alice -- slot start")
        server.succeed("systemctl is-active container@alice.service")
        server.fail("runuser -u alice -- systemctl start agent-slot-start@bob.service")
        server.fail("runuser -u alice -- systemctl start agent-slot-reset-hard@bob.service")
        server.fail("runuser -u alice -- systemctl stop container@alice.service")
        server.fail("runuser -u alice -- systemctl start container@bob.service")
        server.fail("systemctl is-active container@bob.service")
        server.succeed("systemctl is-active container@alice.service")
        server.succeed("journalctl -u agent-slot-start@alice --no-pager | grep -q 'slot alice: start'")
        # systemd itself still refuses the agents: no polkit rule is left
        # that would let them pick a job mode (flush cancels every queued
        # job on the host)
        server.fail("runuser -u alice -- systemctl start --job-mode=flush agent-slot-stop@alice.service")
        server.fail("runuser -u alice -- systemctl start agent-slot-start@alice.service")
        server.fail("grep -rqs agent-slot /etc/polkit-1/")
        server.succeed("systemctl is-active container@alice.service")
        # the socket takes the slot from the caller's uid and one verb only
        sock = "${pkgs.socat}/bin/socat -t 60 - UNIX-CONNECT:/run/agent-slot-ctl.sock"
        for user, line in [("nobody", "start"), ("alice", "start bob"), ("alice", "bogus")]:
            out = server.succeed(f"echo '{line}' | runuser -u {user} -- {sock}")
            assert out.startswith("refused"), (user, line, out)
        server.fail("systemctl is-active container@bob.service")
        server.succeed("runuser -u bob -- slot start")

    with subtest("slot info names the ports, addresses and hostname"):
        info = server.succeed("runuser -u alice -- slot info")
        for want in ["14040-14049", "slot.alice.example.test", alice6, "root@" + alice4, "${publicIPv4}"]:
            assert want in info, info

    with subtest("the slots' hostnames are in exposure.dnsRecords"):
        records = json.load(open("${pkgs.writeText "dns-records.json" (builtins.toJSON nodes.server.services.hyperhermes.exposure.dnsRecords)}"))
        zone = {(r["name"], r["type"]): r["value"] for r in records if "slot" in r["name"]}
        on_link = lambda id: {"ipv6OnLink": {"interface": "br0", "suffix": f"::5107:{id}", "expectedPrefix": "${prefix}"}}
        assert zone == {
            ("slot.alice.example.test", "A"): "${publicIPv4}",
            ("slot.alice.example.test", "AAAA"): on_link(4),
            ("slot.bob.example.test", "A"): "${publicIPv4}",
            ("slot.bob.example.test", "AAAA"): on_link(5),
            # the old names: this host only (no publicIPv6 here, so no AAAA)
            ("alice.slots.test", "A"): "${publicIPv4}",
            ("bob.slots.test", "A"): "${publicIPv4}",
            # and below them, certificates by DNS-01 only
            ("slots.test", "CAA"): '0 issue "letsencrypt.org; validationmethods=dns-01"',
        }, zone

    with subtest("only the owner's key gets in"):
        server.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        server.wait_until_succeeds(ssh_as("bob", bob4), timeout=90)
        server.succeed(ssh_as("alice", alice6))
        # root passes the uid gate: this is the key alone
        server.succeed(ssh_key("alice", alice4))
        server.fail(ssh_key("alice", bob4))
        server.fail(ssh_key("bob", alice4))
        # the host-wide deploy key is not in an agent slot
        keys = server.succeed(in_slot("alice") + "cat /var/lib/container-slot/authorized_keys")
        assert keys.strip() == "${sshKeys.alice.pub}", keys

    with subtest("ssh pins the slot's host key"):
        known = server.succeed("cat /var/lib/container-slots/host-keys/alice/known_hosts").split()
        assert known[0] == f"{alice4},{alice6}", known
        scanned = server.succeed(f"ssh-keyscan -t ed25519 {alice4} 2>/dev/null | grep -v '^#'").split()
        assert scanned[1:3] == known[1:3], (scanned, known)
        # the bootstrap's sshd serves the key the host binds in
        server.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/test -s /var/lib/container-slot/ssh_host_ed25519_key")
        # a slot presenting another key than the pinned one is refused
        # (bob's known_hosts entry, applied to alice's address)
        rc, out = server.execute(f"runuser -u alice -- ssh -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias={bob4} -o UserKnownHostsFile=/var/lib/container-slots/host-keys/bob/known_hosts root@{alice4} true 2>&1")
        assert rc != 0 and "Host key verification failed" in out, out

    with subtest("another uid cannot reach the slot's sshd"):
        for addr in [alice4, alice6]:
            server.succeed(f"runuser -u alice -- nc -z -w 5 {addr} 22")
            server.fail(f"runuser -u bob -- nc -z -w 5 {addr} 22")
        server.succeed(f"nc -z -w 5 {alice4} 22")

    with subtest("a slot reaches the internet, not the host or another slot"):
        curl = in_slot("alice") + "${pkgs.curl}/bin/curl -s -m 5 "
        nc = in_slot("alice") + "${pkgs.netcat-openbsd}/bin/nc -z -w 5 "
        server.succeed(curl + "-f http://${clientIPv4}:8080/")
        server.fail(curl + "http://10.43.4.1/")
        server.fail(curl + "http://${serverIPv4}/")
        server.fail(curl + "http://[${prefix}::2]/")
        server.fail(nc + bob4 + " 22")
        server.fail(nc + bob6 + " 22")

    with subtest("the public IPv4 reaches the right slot"):
        # the guest's firewall is the guest's business: open it
        for name in ["alice", "bob"]:
            server.succeed(f"${pkgs.util-linux}/bin/nsenter -t $(machinectl show {name} -p Leader --value) -n ${pkgs.nftables}/bin/nft flush ruleset")
        serve("alice", "a-http", 80, "alice-http")
        serve("alice", "a-tls", 443, "alice-tls", tls=True)
        serve("alice", "a-port", 14043, "alice-port")
        serve("bob", "b-http", 80, "bob-http")
        serve("bob", "b-tls", 443, "bob-tls", tls=True)
        serve("bob", "b-port", 14050, "bob-port")
        get = "curl -s -m 10 "
        client.wait_until_succeeds(get + "http://${publicIPv4}:14043/ | grep -qx 'alice-port peer=${clientIPv4} xff='", timeout=60)
        client.succeed(get + "http://${publicIPv4}:14050/ | grep -qx 'bob-port peer=${clientIPv4} xff='")
        # a port of alice's range that her slot does not serve is not bob's
        client.fail(get + "http://${publicIPv4}:14044/")
        out = client.succeed(get + "-H 'Host: slot.alice.example.test' http://${publicIPv4}/")
        assert out.strip() == "alice-http peer=10.43.4.1 xff=${clientIPv4}", out
        out = client.succeed(get + "-H 'Host: slot.bob.example.test' http://${publicIPv4}/")
        assert out.startswith("bob-http"), out
        out = client.succeed(get + "-k --resolve slot.alice.example.test:443:${publicIPv4} https://slot.alice.example.test/")
        assert out.strip() == "alice-tls peer=10.43.4.1 xff=", out
        out = client.succeed(get + "-k --resolve slot.bob.example.test:443:${publicIPv4} https://slot.bob.example.test/")
        assert out.startswith("bob-tls"), out
        # the old names: this host answers, with a 301 to the new name (path
        # and query kept), over both ports; nothing reaches a slot
        where = "-o /dev/null -w '%{http_code} %{redirect_url}' "
        out = client.succeed(get + where + "-H 'Host: alice.slots.test' 'http://${publicIPv4}/a?b=1'")
        assert out == "301 https://slot.alice.example.test/a?b=1", out
        # no ACME HTTP-01 challenge for an old name follows that 301 into
        # the slot, on either port
        out = client.succeed(get + where + "-H 'Host: alice.slots.test' 'http://${publicIPv4}/.well-known/acme-challenge/tok'")
        assert out == "404 ", out
        out = client.succeed(get + where + "-k --resolve alice.slots.test:443:${publicIPv4} https://alice.slots.test/.well-known/acme-challenge/tok")
        assert out == "404 ", out
        old = "-k --resolve alice.slots.test:443:${publicIPv4} 'https://alice.slots.test/a?b=1'"
        out = client.succeed(get + where + old)
        assert out == "301 https://slot.alice.example.test/a?b=1", out
        out = client.succeed(get + old)
        assert "alice-tls" not in out and "alice-http" not in out, out
        out = client.succeed(get + where + "-k --resolve bob.slots.test:443:${publicIPv4} https://bob.slots.test/")
        assert out == "301 https://slot.bob.example.test/", out
        out = client.succeed(get + "-o /dev/null -w '%{http_code}' -k --resolve carol.slots.test:443:${publicIPv4} https://carol.slots.test/")
        assert out == "404", out
        # this host's own sites: unchanged, client address intact
        out = client.succeed(get + "-k --resolve server.test:443:${publicIPv4} https://server.test/")
        assert out.strip() == "server ${clientIPv4}", out
        code = client.succeed(get + "-o /dev/null -w '%{http_code}' -H 'Host: server.test' http://${publicIPv4}/")
        assert code == "301", code
        # the helpers hold the slots' namespaces: nspawn would wait on them
        server.succeed("systemctl stop a-http a-tls a-port b-http b-tls b-port")

    with subtest("other agents reach a slot's public v6 like the internet, nothing else"):
        serve("alice", "a-any", 14043, "alice-any")
        serve("alice", "a-any6", 8086, "alice-any6", v6=True)
        server.succeed(f"systemd-run --unit=a-udp6 {in_slot('alice')} ${pkgs.socat}/bin/socat UDP6-RECVFROM:8087,fork SYSTEM:'echo alice-udp'")
        server.wait_until_succeeds(f"nc -z -w 5 {alice4} 14043", timeout=30)
        server.wait_until_succeeds(f"nc -z -w 5 {alice6} 8086", timeout=30)
        nginx = "setpriv --reuid=nginx --regid=nginx --clear-groups "
        for target in [f"{alice4} 14043", f"{alice6} 8086"]:
            server.succeed(f"runuser -u alice -- nc -z -w 5 {target}")
            server.succeed(f"nc -z -w 5 {target}")
            server.succeed(nginx + f"nc -z -w 5 {target}")
        # bob: the public v6, TCP and UDP, on a port that is not ssh ...
        out = server.succeed(f"runuser -u bob -- curl -g -s -m 10 'http://[{alice6}]:8086/'")
        assert out.startswith("alice-any6"), out
        # ... from this host's uplink address, as the slot's v6 gateway (the
        # veth's host side) is deprecated; never the proxy hop 10.43.4.1
        src = ipaddress.ip_address(peer(out))
        assert src == ipaddress.ip_address("${prefix}::2"), out
        assert src not in ipaddress.ip_network("fd43:5107::/64") and not src.is_link_local, out
        udp6 = f"echo hi | runuser -u bob -- ${pkgs.socat}/bin/socat -t 5 -T 5 - 'UDP6:[{alice6}]:8087'"
        server.wait_until_succeeds(udp6 + " | grep -qx alice-udp", timeout=30)
        # ... but not from the veth's host side, picked by hand
        server.fail(f"runuser -u bob -- nc -z -w 5 -s fd43:5107::4:1 {alice6} 8086")
        server.succeed(f"runuser -u alice -- nc -z -w 5 -s fd43:5107::4:1 {alice6} 8086")
        # the internal v4, where the proxies come from: no port at all
        server.fail(f"runuser -u bob -- nc -z -w 5 {alice4} 14043")
        server.fail(f"runuser -u bob -- ${pkgs.curl}/bin/curl -s -m 5 -H 'X-Forwarded-For: 1.2.3.4' http://{alice4}:14043/")
        # Every packet is gated, not only a flow's first: alice holds a UDP
        # flow to her slot's v4 from port 40000 with SO_REUSEADDR, which
        # lets bob bind the same port (no uid check for REUSEADDR) and send
        # on her established conntrack entry. The slot must not hear him.
        assert "ct state" not in server.succeed("nft list chain inet agent-slots output")
        grep = "${pkgs.gnugrep}/bin/grep"
        server.succeed(f"systemd-run --unit=a-udp4 {in_slot('alice')} ${pkgs.socat}/bin/socat UDP4-LISTEN:9999 SYSTEM:'${pkgs.coreutils}/bin/tee -a /root/udp.log'")
        server.succeed(f"systemd-run --unit=alice-udp --uid=alice ${pkgs.socat}/bin/socat UDP4:{alice4}:9999,sourceport=40000,reuseaddr SYSTEM:'echo alice; ${pkgs.coreutils}/bin/cat >/tmp/alice-udp.reply; true'")
        # the slot echoed: the flow is established both ways
        server.wait_until_succeeds(f"{grep} -qx alice /tmp/alice-udp.reply", timeout=30)
        server.execute(f"echo bob | runuser -u bob -- ${pkgs.socat}/bin/socat -u - UDP4-SENDTO:{alice4}:9999,sourceport=40000,reuseaddr")
        server.sleep(2)
        heard = server.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/cat /root/udp.log")
        assert heard.split() == ["alice"], heard
        server.succeed("systemctl stop alice-udp a-udp4 a-udp6")

    with subtest("a slot's own connections leave only through the egress link"):
        curl = in_slot("alice") + "${pkgs.curl}/bin/curl -s -m 5 -g "
        out = server.succeed(curl + "http://${clientIPv4}:8081/")
        assert "peer=${tunnelIPv4}" in out, out
        out = server.succeed(curl + "'http://[${clientIPv6}]:8081/'")
        assert peer(out) == "${tunnelIPv6}", out
        out = server.succeed("ip route get ${clientIPv4} from 10.43.4.2 iif ve-alice mark 0x2000000")
        assert "dev eth2" in out, out
        # Inbound keeps answering the way it came: v6 straight back over
        # br0 (down the tunnel the relay would drop it), forwarded v4 back
        # over the public IPv4's link (eth3).
        out = client.succeed("curl -g -s -m 10 'http://[" + alice6 + "]:8086/'")
        assert peer(out) == "${clientIPv6}", out
        out = client.succeed("curl -s -m 10 http://${publicIPv4}:14043/")
        assert "peer=${clientIPv4}" in out, out
        # kill switch: without the egress routes, nothing leaves another way
        server.succeed("ip route flush table ${toString egressTable}")
        server.succeed("ip -6 route flush table ${toString egressTable}")
        server.fail(curl + "http://${clientIPv4}:8081/")
        server.fail(curl + "'http://[${clientIPv6}]:8081/'")
        out = client.succeed("curl -g -s -m 10 'http://[" + alice6 + "]:8086/'")
        assert peer(out) == "${clientIPv6}", out
        server.succeed("ip route add default via ${relayIPv4} dev eth2 table ${toString egressTable}")
        server.succeed("ip -6 route add default via ${relayIPv6} dev eth2 table ${toString egressTable}")
        server.succeed(curl + "-f http://${clientIPv4}:8081/")
        server.succeed("systemctl stop a-any a-any6")

    with subtest("blocked destinations (the routers' WAN side) stay out of reach"):
        nc = in_slot("alice") + "${pkgs.netcat-openbsd}/bin/nc -z -w 5 "
        # routed down the egress link like any destination, then dropped
        out = server.succeed("ip route get ${routerWanIPv4} from 10.43.4.2 iif ve-alice mark 0x2000000")
        assert "dev eth2" in out, out
        server.succeed(nc + "${clientIPv4} 8081")
        server.fail(nc + "${routerWanIPv4} 8081")
        server.fail(nc + "${routerWanIPv6} 8081")

    with subtest("the slots run in agent-slots.slice, under its limits"):
        assert server.succeed("systemctl show container@alice.service -p Slice --value").strip() == "agent-slots.slice"
        props = server.succeed("systemctl show agent-slots.slice -p MemoryMax -p MemoryHigh -p TasksMax -p IOWeight -p CPUWeight")
        for want in ["MemoryMax=12884901888", "MemoryHigh=10737418240", "TasksMax=8192", "IOWeight=20", "CPUWeight=20"]:
            assert want in props, props
        assert server.succeed("systemctl show container@alice.service -p TasksMax --value").strip() == "2048"
        server.succeed("machinectl status alice >/dev/null")

    with subtest("a slot cannot steer the host's start script through symlinks"):
        root = "/var/lib/nixos-containers/alice"
        server.succeed("install -d -m 0755 /srv/probe && install -d -m 0700 /var/lib/private")
        modes = lambda: server.succeed("stat -c '%n %a' / /root /var/lib /var/lib/private /srv/probe")
        before = modes()
        # the guest, as its root, swaps its /root for a link to /
        server.succeed(in_slot("alice") + "${pkgs.bash}/bin/sh -c 'rm -rf /root && ln -s / /root'")
        server.succeed("runuser -u alice -- slot stop")
        server.fail("runuser -u alice -- slot start")
        server.fail("systemctl is-active container@alice.service")
        server.succeed("journalctl -u container@alice --no-pager | grep -q '/root in the slot is a symlink'")
        assert modes() == before, (before, modes())
        # what it could plant just as well (set here from the host, the
        # slot being down): /var/lib/private -> a host directory
        server.succeed(f"rm {root}/root && mkdir -m 0700 {root}/root")
        server.succeed(f"rm -rf {root}/var/lib/private && ln -s /srv/probe {root}/var/lib/private")
        server.fail("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        server.succeed("journalctl -u container@alice --no-pager | grep -q '/var/lib/private in the slot is a symlink'")
        server.succeed(f"rm {root}/var/lib/private && mkdir -m 0700 {root}/var/lib/private")
        server.succeed(f"rm -rf {root}/var/lib && ln -s /var/lib/private {root}/var/lib")
        server.fail("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        server.succeed("journalctl -u container@alice --no-pager | grep -q ': /var/lib in the slot is a symlink'")
        assert modes() == before, (before, modes())
        # dangling links where the script touches or copies a file: removed,
        # the slot starts, nothing appears on the host
        server.succeed(f"rm {root}/var/lib && mkdir -m 0755 {root}/var/lib")
        server.succeed(f"ln -sfn /srv/nologin-probe {root}/etc/machine-id && ln -sfn /srv/probe/resolv {root}/etc/resolv.conf")
        server.succeed("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        server.succeed("test ! -e /srv/nologin-probe && test ! -e /srv/probe/resolv")
        server.succeed(f"test ! -L {root}/etc/machine-id && test ! -L {root}/etc/resolv.conf")
        assert modes() == before, (before, modes())
        # a machine-id link to a file that exists on the host goes too:
        # its target's existence is host state the agent can flip
        server.succeed("systemctl stop container@alice.service")
        server.succeed("echo keep > /srv/mid-probe && touch -d @1000000000 /srv/mid-probe")
        server.succeed(f"ln -sfn /srv/mid-probe {root}/etc/machine-id")
        server.succeed("systemctl start container@alice.service")
        server.succeed(f"test ! -L {root}/etc/machine-id")
        server.succeed("test \"$(stat -c %Y /srv/mid-probe)\" = 1000000000 && grep -qx keep /srv/mid-probe")
        # a NixOS guest's own /etc/os-release link does not stop it
        server.succeed(f"test -L {root}/etc/os-release")
        # The agent's way out is a hard reset, which also drops the gc
        # roots the guest made (through its bind of gcroots/per-container).
        server.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/ln -s ${broken} /nix/var/nix/gcroots/pin")
        server.succeed("test -L /nix/var/nix/gcroots/per-container/alice/pin")
        server.succeed("runuser -u alice -- slot reset --hard")
        server.succeed("test ! -e /nix/var/nix/gcroots/per-container/alice/pin")
        server.succeed("systemctl is-active container@alice.service")
        server.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)

    with subtest("the desired state survives a reboot"):
        server.succeed("runuser -u bob -- slot stop")
        server.fail("systemctl is-active container@bob.service")
        # A stopped slot's addresses lead nowhere, not to the default
        # route or the LAN /64 (where any peer could claim the v6).
        server.fail(f"ip route get {bob4}")
        server.fail(f"ip -6 route get {bob6}")
        assert "dev ve-alice" in server.succeed(f"ip route get {alice4}")
        assert "dev ve-alice" in server.succeed(f"ip -6 route get {alice6}")
        server.fail(ssh_as("bob", bob4))
        # A power cut, not a clean shutdown: the state written by the
        # control units must already be on disk (and this VM's read-only
        # store image keeps a clean poweroff from ever finishing).
        server.crash()
        server.start()
        server.wait_for_unit("agent-slots-restore.service")
        server.wait_for_unit("container@alice.service")
        server.fail("systemctl is-active container@bob.service")
        assert "desired off" in server.succeed("runuser -u bob -- slot status")
        server.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)

    with subtest("a reset brings back a slot whose deploy dropped sshd"):
        # What a deploy of a system without sshd leaves behind: the slot's
        # profile on it, and the slot rebooted into it. Set from the host:
        # this VM's store is read-only, so nix inside the slot cannot.
        server.succeed("nix-env -p /nix/var/nix/profiles/per-container/alice/system --set ${broken}")
        server.succeed("systemctl restart container@alice.service")
        server.sleep(10)
        server.fail(ssh_as("alice", alice4))
        server.succeed("runuser -u alice -- slot reset")
        server.succeed("systemctl is-active container@alice.service")
        server.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        server.succeed(ssh_as("alice", alice4, "'touch /root/marker'"))
        server.succeed("journalctl -u agent-slot-reset@alice --no-pager | grep -q 'slot alice: reset, then back to on'")

    with subtest("a hard reset also wipes the slot, and keeps it off when it was off"):
        server.succeed("runuser -u alice -- slot reset --hard")
        server.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        server.fail(ssh_as("alice", alice4, "'test -e /root/marker'"))
        server.succeed("runuser -u bob -- slot reset --hard")
        server.fail("systemctl is-active container@bob.service")
        assert "desired off" in server.succeed("runuser -u bob -- slot status")

    with subtest("control units are rate-limited"):
        # bob's earlier stop still counts: at most 6 in 10 minutes in all
        ok = 0
        while server.execute("runuser -u bob -- slot stop")[0] == 0:
            ok += 1
            assert ok <= 6, "no rate limit"
        assert ok >= 4, ok
        server.succeed("journalctl -u agent-slot-stop@bob --no-pager | grep -q 'stop refused, 6 already'")
        # per action: a start still goes through
        server.succeed("runuser -u bob -- slot start")
  '';
}
