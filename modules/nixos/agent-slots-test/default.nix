# Agent slots (../agent-slots.nix) on a som-like host with two agents,
# alice (slot 4) and bob (slot 5), behind a simulated sgp: `gateway` runs
# the real ../ipv4-forward.nix gateway on 38.89.142.76 and `client` plays
# the internet, and on a second link (vlan 2) a Mullvad relay: the stand-in
# for wg-mullvad, which accepts only the tunnel's own source addresses, as
# a relay does. Covered: each agent starts, stops and resets only its own
# slot, through the control socket and never through systemd itself (no
# --job-mode=flush); only its key gets in, only its uid (and root, nginx)
# reaches the slot's ssh, internal v4 and veth, every packet of a flow,
# while the other agent reaches the public v6 like the internet does (TCP
# and UDP, from the uplink address, never the proxy hop or the veth's host
# side), and its ssh pins the slot's host key; the
# slots reach the internet only through the egress link (kill switch),
# never the host, each other or the blocked destinations, while inbound v6
# and forwarded v4 answer the way they came; a slot cannot steer the
# host's start script through symlinks in its root; stopped slots' addresses
# are unreachable; the desired state survives a reboot; a reset brings back
# a slot whose deploy dropped sshd, a hard reset also drops its gc roots;
# the slots run in agent-slots.slice; the public IPv4 reaches the right slot
# by port, by Host (80) and by SNI (443) under slot.<agent>.<domain>, with
# the host's own https site keeping the client address; the old names
# <agent>.<legacyDomain> only answer this host's 301 to the new one, path
# kept, and never reach a slot; the return mark leaves the Mullvad app's
# mark alone; each slot's hostname gets its A and AAAA, each old name its
# A, at a stub of porkbun's API.
{ pkgs, spaces }:
let
  inherit (pkgs) lib;

  # Test-only keys.
  wgKeys = {
    sgp = "UGJQE4KIqVRoTnfJ4X6YiJNvMt1Vcock2T3t+Vu2vkg=";
    som = "iI9wf7ORSTshbaYsdF62m0yhoi3wRA7v8CpAIWaRxHk=";
  };
  sshKeys = {
    alice = {
      pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC48uSUhvbKLmlJkJ7/GN6oqJsnCfwS1I+G/4EN45Dpq alice@test";
      priv = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACAuPLklIb2yi5pSZCe/xjeqKibJwn8EtSPhv+BDeOQ6agAAAJDYDATc2AwE
        3AAAAAtzc2gtZWQyNTUxOQAAACAuPLklIb2yi5pSZCe/xjeqKibJwn8EtSPhv+BDeOQ6ag
        AAAECoo8ej+H46tA9S9hBEfAzwYk87SiqBE5o6cg4062uGnC48uSUhvbKLmlJkJ7/GN6oq
        JsnCfwS1I+G/4EN45DpqAAAACmFsaWNlQHRlc3QBAgM=
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
    bob = {
      pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFXatIXf1FCzdfJMe5d58yYJ8adZmrmL6ls7AcqrIVF bob@test";
      priv = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACCRV2rSF39RQs3XyTHuXefMmCfGnWZq5i+pbOwHKqyFRQAAAJDNhluazYZb
        mgAAAAtzc2gtZWQyNTUxOQAAACCRV2rSF39RQs3XyTHuXefMmCfGnWZq5i+pbOwHKqyFRQ
        AAAECjOpnJjIFCoi8WnQd31Kjs6MgkjMvmJWvJXG+8AYNfaJFXatIXf1FCzdfJMe5d58yY
        J8adZmrmL6ls7AcqrIVFAAAACGJvYkB0ZXN0AQIDBAU=
        -----END OPENSSH PRIVATE KEY-----
      '';
    };
  };
  adminKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU admin@test";

  publicIPv4 = "38.89.142.76";
  clientIPv4 = "38.89.142.10";
  somIPv4 = "38.89.142.2";
  prefix = "2001:db8:1:2";
  # "the internet" over v6, and the stand-ins for the routers' WAN side
  clientIPv6 = "2001:db8:ffff::10";
  routerWanIPv4 = "198.51.100.1";
  routerWanIPv6 = "2001:db8:fffe::1";
  # the egress link (wg-mullvad on som): som's end, the relay's end
  tunnelIPv4 = "10.64.0.2";
  tunnelIPv6 = "fd00:64::2";
  relayIPv4 = "10.64.0.1";
  relayIPv6 = "fd00:64::1";
  egressTable = 51830;

  # What clan provides to ../ipv4-forward.nix: the generator declarations
  # (ignored here), each file's deployed path, and the repo directory the
  # peer's public key is read from.
  clanStub =
    { lib, ... }:
    {
      options.clan.core.settings.directory = lib.mkOption { type = lib.types.path; };
      options.clan.core.vars.generators = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            let
              generator = name;
            in
            {
              freeformType = lib.types.attrsOf lib.types.anything;
              options.files = lib.mkOption {
                default = { };
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    { name, ... }:
                    {
                      freeformType = lib.types.attrsOf lib.types.anything;
                      options.path = lib.mkOption {
                        type = lib.types.str;
                        default = "/etc/test-vars/${generator}/${name}";
                      };
                    }
                  )
                );
              };
            }
          )
        );
      };
      config.clan.core.settings.directory = ./.;
    };

  wgNode = machine: {
    imports = [
      clanStub
      ../ipv4-forward.nix
    ];
    environment.etc."test-vars/ipv4-forward-wg/privateKey" = {
      text = wgKeys.${machine};
      mode = "0640";
      group = "systemd-network";
    };
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.wait-online.enable = false;
  };

  # One self-signed certificate for every name in the test.
  cert = pkgs.runCommand "agent-slots-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test \
      -addext "subjectAltName=DNS:som.test,DNS:slot.alice.fyi.test,DNS:slot.bob.fyi.test" \
      -keyout $out/key.pem -out $out/cert.pem
  '';

  # Answers one HTTP request with its tag, the peer it saw and the
  # X-Forwarded-For it got (socat sets SOCAT_PEERADDR).
  responder = pkgs.writeShellScript "responder" ''
    xff=""
    while IFS= read -r line; do
      line=''${line%$'\r'}
      [ -z "$line" ] && break
      case "$line" in [Xx]-[Ff]orwarded-[Ff]or:*) xff=''${line#*: } ;; esac
    done
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n%s peer=%s xff=%s\n' "$1" "$SOCAT_PEERADDR" "$xff"
  '';

  # `nix-env -p <profile> --set <path>` as symlinks: <profile>-<n>-link to
  # the path, <profile> to the newest link (see nix.package below).
  profileSet = pkgs.writeShellScript "nix-env" ''
    if [ "$#" -ne 4 ] || [ "$1" != -p ] || [ "$3" != --set ]; then
      echo "nix-env stand-in: only -p <profile> --set <path>" >&2
      exit 1
    fi
    p=$2
    n=1
    while [ -e "$p-$n-link" ] || [ -L "$p-$n-link" ]; do n=$((n + 1)); done
    ${pkgs.coreutils}/bin/ln -s "$4" "$p-$n-link"
    ${pkgs.coreutils}/bin/ln -sfn "$(${pkgs.coreutils}/bin/basename "$p")-$n-link" "$p"
  '';

  # A deploy that drops sshd: what locks an agent out of its slot.
  broken =
    (pkgs.nixos {
      boot.isNspawnContainer = true;
      networking.hostName = "";
      system.stateVersion = lib.trivial.release;
    }).toplevel;

  porkbunStub = pkgs.writers.writePython3 "porkbun-stub" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ../porkbun-records/stub.py
  );
in
pkgs.testers.runNixOSTest {
  name = "agent-slots";
  globalTimeout = 1800;

  nodes.client = {
    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
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
    # The slots' /64 sits behind som's proxy NDP on this link.
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
    # som sends down the tunnel unmasqueraded (a reply to an inbound
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

  nodes.gateway = {
    imports = [ (wgNode "sgp") ];
    hyper.ipv4Forward.role = "gateway";
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = publicIPv4;
        prefixLength = 24;
      }
    ];
  };

  nodes.som =
    { config, ... }:
    {
      imports = [
        (wgNode "som")
        ../container-slots.nix
        ../agent-slots.nix
        ../hermes-native/options.nix
      ];
      _module.args.inputs = { inherit spaces; };
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      virtualisation.vlans = [
        1
        2
      ];

      hyper.ipv4Forward.role = "backend";

      # The egress link, as ../mullvad-egress/egress.nix sets up wg-mullvad:
      # its own table with default routes, loose reverse-path checks.
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
      # As on som (../vpn.nix): isolatedEgress needs a loose rpfilter.
      networking.firewall.checkReversePath = "loose";

      # nspawn idmaps /nix/store into a slot with its own user namespace;
      # neither the host's virtiofs share nor the writable overlay on it
      # allows that, a read-only store image (erofs) does (on som: zfs).
      virtualisation.useNixStoreImage = true;
      virtualisation.writableStore = false;
      # nix cannot open that store at all (LocalStore creates
      # /nix/store/.links even in read-only mode), so the seed's
      # `nix-env -p <profile> --set <system>` gets a stand-in that writes
      # the same generation symlinks; on som the real one runs.
      nix.package = pkgs.symlinkJoin {
        inherit (pkgs.nix) pname version;
        passthru = pkgs.nix.passthru;
        paths = [ pkgs.nix ];
        postBuild = ''
          rm $out/bin/nix-env
          cp ${profileSet} $out/bin/nix-env
        '';
      };
      # nspawn binds the db into every slot; nothing here ever opens it.
      systemd.tmpfiles.rules = [ "d /nix/var/nix/db 0755 root root -" ];

      # The uplink becomes a port of br0, which carries the address.
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      systemd.network.networks."40-br0".address = [
        "${somIPv4}/24"
        "${prefix}::2/64"
      ];
      # the v6 "internet" client, on-link here (it reaches the slots by NDP)
      systemd.network.networks."40-br0".routes = [ { Destination = "2001:db8:ffff::/64"; } ];
      hyper.containerSlots = {
        enable = true;
        uplink = "eth1";
        # the test driver's MAC for this node on vlan 1
        uplinkMac = "52:54:00:12:01:${lib.fixedWidthString 2 "0" (lib.toHexString config.virtualisation.test.nodeNumber)}";
        ipv6Prefix = prefix;
        deployKeys = [ adminKey ];
        publicIPv4Interface = "wg-v4fwd";
        isolatedEgress = {
          interface = "eth2";
          table = egressTable;
        };
        isolatedBlockedDestinations = [
          routerWanIPv4
          routerWanIPv6
        ];
      };

      hyper.agentSlots = {
        domain = "fyi.test";
        legacyDomain = "slots.test";
        inherit publicIPv4;
        agents = lib.mapAttrs (name: id: {
          inherit id;
          deployKey = sshKeys.${name}.pub;
          identityFile = "/etc/agent-keys/${name}";
        }) { alice = 4; bob = 5; };
      };

      # DNS for the slots (../porkbun-records), against its test's stub of
      # porkbun's API; the test runs the unit itself.
      hyper.porkbunRecords = {
        apiBase = "http://127.0.0.1:8053/api/json/v3";
        apiKeyFile = "${pkgs.writeText "apikey" "test-key"}";
        secretKeyFile = "${pkgs.writeText "secretkey" "test-secret"}";
      };
      systemd.timers.porkbun-records.timerConfig.OnBootSec = lib.mkForce "1d";
      systemd.services.porkbun-stub = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${porkbunStub} 8053 ${pkgs.writeText "seed.json" "[]"}";
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
        ) sshKeys
        # the porkbun var the old names' DNS-01 certificate names
        // {
          "test-vars/porkbun/apikey".text = "unused";
          "test-vars/porkbun/secretkey".text = "unused";
        };

      # This host's own https site (as hermes.davhau.com on som); it sorts
      # before the slot vhosts, as som's own do.
      services.nginx.virtualHosts.host-site = {
        serverName = "som.test";
        forceSSL = true;
        sslCertificate = "${cert}/cert.pem";
        sslCertificateKey = "${cert}/key.pem";
        locations."/".return = "200 'som $remote_addr\\n'";
        extraConfig = "default_type text/plain;";
      };
      # The old names' DNS-01 certificate: no ACME server here, so the
      # self-signed placeholder stays and the renewals fail fast.
      security.acme = {
        acceptTerms = true;
        defaults.email = "test@example.org";
        defaults.server = "https://127.0.0.1:1/directory";
      };
      # clan turns persisted prompts into files; the stub does not.
      clan.core.vars.generators.porkbun.files = {
        apikey = { };
        secretkey = { };
      };

      system.extraDependencies = [ broken ];
      # the agents' tools (hermes-native puts them on the agents' PATH;
      # here system-wide, so runuser finds them)
      environment.systemPackages = config.services.hermes-native.extraPackages ++ [
        pkgs.curl
        pkgs.netcat-openbsd
      ];
    };

  testScript = ''
    import ipaddress
    import json

    def in_slot(name):
        return f"${pkgs.util-linux}/bin/nsenter -t $(machinectl show {name} -p Leader --value) -a "

    def serve(name, unit, port, tag, tls=False, v6=False):
        listen = (f"OPENSSL-LISTEN:{port},cert=${cert}/cert.pem,key=${cert}/key.pem,verify=0" if tls
                  else f"TCP6-LISTEN:{port},ipv6only=1" if v6
                  else f"TCP-LISTEN:{port}")
        som.succeed(f"systemd-run --unit={unit} {in_slot(name)} ${pkgs.socat}/bin/socat {listen},fork,reuseaddr EXEC:'${responder} {tag}'")

    # the peer a responder reports, v6 in its compressed form
    def peer(out):
        return str(ipaddress.ip_address(out.split("peer=", 1)[1].split()[0].strip("[]")))

    ssh_as = lambda user, addr, cmd="true": f"runuser -u {user} -- ssh -o BatchMode=yes -o ConnectTimeout=5 root@{addr} {cmd}"
    ssh_key = lambda key, addr: f"ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i /etc/agent-keys/{key} root@{addr} true"
    alice4, bob4 = "10.43.4.2", "10.43.5.2"
    alice6, bob6 = "${prefix}::5107:4", "${prefix}::5107:5"

    start_all()
    som.wait_for_unit("multi-user.target")
    som.wait_for_unit("nginx.service")
    client.wait_for_unit("web.service")
    som.wait_until_succeeds("ping -c1 -W1 10.99.0.1", timeout=60)

    with subtest("slots exist but are off by default"):
        som.succeed("systemctl cat container@alice.service >/dev/null")
        som.fail("systemctl is-active container@alice.service")
        assert "desired off" in som.succeed("runuser -u alice -- slot status")

    with subtest("an agent controls its own slot only"):
        som.succeed("runuser -u alice -- slot start")
        som.succeed("systemctl is-active container@alice.service")
        som.fail("runuser -u alice -- systemctl start agent-slot-start@bob.service")
        som.fail("runuser -u alice -- systemctl start agent-slot-reset-hard@bob.service")
        som.fail("runuser -u alice -- systemctl stop container@alice.service")
        som.fail("runuser -u alice -- systemctl start container@bob.service")
        som.fail("systemctl is-active container@bob.service")
        som.succeed("systemctl is-active container@alice.service")
        som.succeed("journalctl -u agent-slot-start@alice --no-pager | grep -q 'slot alice: start'")
        # systemd itself still refuses the agents: no polkit rule is left
        # that would let them pick a job mode (flush cancels every queued
        # job on the host)
        som.fail("runuser -u alice -- systemctl start --job-mode=flush agent-slot-stop@alice.service")
        som.fail("runuser -u alice -- systemctl start agent-slot-start@alice.service")
        som.fail("grep -rqs agent-slot /etc/polkit-1/")
        som.succeed("systemctl is-active container@alice.service")
        # the socket takes the slot from the caller's uid and one verb only
        sock = "${pkgs.socat}/bin/socat -t 60 - UNIX-CONNECT:/run/agent-slot-ctl.sock"
        for user, line in [("nobody", "start"), ("alice", "start bob"), ("alice", "bogus")]:
            out = som.succeed(f"echo '{line}' | runuser -u {user} -- {sock}")
            assert out.startswith("refused"), (user, line, out)
        som.fail("systemctl is-active container@bob.service")
        som.succeed("runuser -u bob -- slot start")

    with subtest("slot info names the ports, addresses and hostname"):
        info = som.succeed("runuser -u alice -- slot info")
        for want in ["14040-14049", "slot.alice.fyi.test", alice6, "root@" + alice4, "${publicIPv4}"]:
            assert want in info, info

    with subtest("the slots' hostnames are published"):
        som.wait_for_unit("porkbun-stub.service")
        som.wait_until_succeeds("curl -sf http://127.0.0.1:8053/_records", timeout=30)
        som.succeed("systemctl start porkbun-records")
        zone = {(r["name"], r["type"]): r["content"] for r in json.loads(som.succeed("curl -sf http://127.0.0.1:8053/_records"))}
        assert zone == {
            ("slot.alice.fyi.test", "A"): "${publicIPv4}",
            ("slot.alice.fyi.test", "AAAA"): alice6,
            ("slot.bob.fyi.test", "A"): "${publicIPv4}",
            ("slot.bob.fyi.test", "AAAA"): bob6,
            # the old names: this host only (no publicIPv6 here, so no AAAA)
            ("alice.slots.test", "A"): "${publicIPv4}",
            ("bob.slots.test", "A"): "${publicIPv4}",
            # and below them, certificates by DNS-01 only
            ("slots.test", "CAA"): '0 issue "letsencrypt.org; validationmethods=dns-01"',
        }, zone

    with subtest("only the owner's key gets in"):
        som.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        som.wait_until_succeeds(ssh_as("bob", bob4), timeout=90)
        som.succeed(ssh_as("alice", alice6))
        # root passes the uid gate: this is the key alone
        som.succeed(ssh_key("alice", alice4))
        som.fail(ssh_key("alice", bob4))
        som.fail(ssh_key("bob", alice4))
        # the host-wide deploy key is not in an agent slot
        keys = som.succeed(in_slot("alice") + "cat /var/lib/container-slot/authorized_keys")
        assert keys.strip() == "${sshKeys.alice.pub}", keys

    with subtest("ssh pins the slot's host key"):
        known = som.succeed("cat /var/lib/container-slots/host-keys/alice/known_hosts").split()
        assert known[0] == f"{alice4},{alice6}", known
        scanned = som.succeed(f"ssh-keyscan -t ed25519 {alice4} 2>/dev/null | grep -v '^#'").split()
        assert scanned[1:3] == known[1:3], (scanned, known)
        # the bootstrap's sshd serves the key the host binds in
        som.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/test -s /var/lib/container-slot/ssh_host_ed25519_key")
        # a slot presenting another key than the pinned one is refused
        # (bob's known_hosts entry, applied to alice's address)
        rc, out = som.execute(f"runuser -u alice -- ssh -o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias={bob4} -o UserKnownHostsFile=/var/lib/container-slots/host-keys/bob/known_hosts root@{alice4} true 2>&1")
        assert rc != 0 and "Host key verification failed" in out, out

    with subtest("another uid cannot reach the slot's sshd"):
        for addr in [alice4, alice6]:
            som.succeed(f"runuser -u alice -- nc -z -w 5 {addr} 22")
            som.fail(f"runuser -u bob -- nc -z -w 5 {addr} 22")
        som.succeed(f"nc -z -w 5 {alice4} 22")

    with subtest("a slot reaches the internet, not the host or another slot"):
        curl = in_slot("alice") + "${pkgs.curl}/bin/curl -s -m 5 "
        nc = in_slot("alice") + "${pkgs.netcat-openbsd}/bin/nc -z -w 5 "
        som.succeed(curl + "-f http://${clientIPv4}:8080/")
        som.fail(curl + "http://10.43.4.1/")
        som.fail(curl + "http://${somIPv4}/")
        som.fail(curl + "http://[${prefix}::2]/")
        som.fail(nc + bob4 + " 22")
        som.fail(nc + bob6 + " 22")

    with subtest("the public IPv4 reaches the right slot"):
        # the guest's firewall is the guest's business: open it
        for name in ["alice", "bob"]:
            som.succeed(f"${pkgs.util-linux}/bin/nsenter -t $(machinectl show {name} -p Leader --value) -n ${pkgs.nftables}/bin/nft flush ruleset")
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
        out = client.succeed(get + "-H 'Host: slot.alice.fyi.test' http://${publicIPv4}/")
        assert out.strip() == "alice-http peer=10.43.4.1 xff=${clientIPv4}", out
        out = client.succeed(get + "-H 'Host: slot.bob.fyi.test' http://${publicIPv4}/")
        assert out.startswith("bob-http"), out
        out = client.succeed(get + "-k --resolve slot.alice.fyi.test:443:${publicIPv4} https://slot.alice.fyi.test/")
        assert out.strip() == "alice-tls peer=10.43.4.1 xff=", out
        out = client.succeed(get + "-k --resolve slot.bob.fyi.test:443:${publicIPv4} https://slot.bob.fyi.test/")
        assert out.startswith("bob-tls"), out
        # the old names: this host answers, with a 301 to the new name (path
        # and query kept), over both ports; nothing reaches a slot
        where = "-o /dev/null -w '%{http_code} %{redirect_url}' "
        out = client.succeed(get + where + "-H 'Host: alice.slots.test' 'http://${publicIPv4}/a?b=1'")
        assert out == "301 https://slot.alice.fyi.test/a?b=1", out
        # no ACME HTTP-01 challenge for an old name follows that 301 into
        # the slot, on either port
        out = client.succeed(get + where + "-H 'Host: alice.slots.test' 'http://${publicIPv4}/.well-known/acme-challenge/tok'")
        assert out == "404 ", out
        out = client.succeed(get + where + "-k --resolve alice.slots.test:443:${publicIPv4} https://alice.slots.test/.well-known/acme-challenge/tok")
        assert out == "404 ", out
        old = "-k --resolve alice.slots.test:443:${publicIPv4} 'https://alice.slots.test/a?b=1'"
        out = client.succeed(get + where + old)
        assert out == "301 https://slot.alice.fyi.test/a?b=1", out
        out = client.succeed(get + old)
        assert "alice-tls" not in out and "alice-http" not in out, out
        out = client.succeed(get + where + "-k --resolve bob.slots.test:443:${publicIPv4} https://bob.slots.test/")
        assert out == "301 https://slot.bob.fyi.test/", out
        out = client.succeed(get + "-o /dev/null -w '%{http_code}' -k --resolve carol.slots.test:443:${publicIPv4} https://carol.slots.test/")
        assert out == "404", out
        # this host's own sites: unchanged, client address intact
        out = client.succeed(get + "-k --resolve som.test:443:${publicIPv4} https://som.test/")
        assert out.strip() == "som ${clientIPv4}", out
        code = client.succeed(get + "-o /dev/null -w '%{http_code}' -H 'Host: som.test' http://${publicIPv4}/")
        assert code == "301", code
        # the helpers hold the slots' namespaces: nspawn would wait on them
        som.succeed("systemctl stop a-http a-tls a-port b-http b-tls b-port")

    with subtest("other agents reach a slot's public v6 like the internet, nothing else"):
        serve("alice", "a-any", 14043, "alice-any")
        serve("alice", "a-any6", 8086, "alice-any6", v6=True)
        som.succeed(f"systemd-run --unit=a-udp6 {in_slot('alice')} ${pkgs.socat}/bin/socat UDP6-RECVFROM:8087,fork SYSTEM:'echo alice-udp'")
        som.wait_until_succeeds(f"nc -z -w 5 {alice4} 14043", timeout=30)
        som.wait_until_succeeds(f"nc -z -w 5 {alice6} 8086", timeout=30)
        nginx = "setpriv --reuid=nginx --regid=nginx --clear-groups "
        for target in [f"{alice4} 14043", f"{alice6} 8086"]:
            som.succeed(f"runuser -u alice -- nc -z -w 5 {target}")
            som.succeed(f"nc -z -w 5 {target}")
            som.succeed(nginx + f"nc -z -w 5 {target}")
        # bob: the public v6, TCP and UDP, on a port that is not ssh ...
        out = som.succeed(f"runuser -u bob -- curl -g -s -m 10 'http://[{alice6}]:8086/'")
        assert out.startswith("alice-any6"), out
        # ... from this host's uplink address, as the slot's v6 gateway (the
        # veth's host side) is deprecated; never the proxy hop 10.43.4.1
        src = ipaddress.ip_address(peer(out))
        assert src == ipaddress.ip_address("${prefix}::2"), out
        assert src not in ipaddress.ip_network("fd43:5107::/64") and not src.is_link_local, out
        udp6 = f"echo hi | runuser -u bob -- ${pkgs.socat}/bin/socat -t 5 -T 5 - 'UDP6:[{alice6}]:8087'"
        som.wait_until_succeeds(udp6 + " | grep -qx alice-udp", timeout=30)
        # ... but not from the veth's host side, picked by hand
        som.fail(f"runuser -u bob -- nc -z -w 5 -s fd43:5107::4:1 {alice6} 8086")
        som.succeed(f"runuser -u alice -- nc -z -w 5 -s fd43:5107::4:1 {alice6} 8086")
        # the internal v4, where the proxies come from: no port at all
        som.fail(f"runuser -u bob -- nc -z -w 5 {alice4} 14043")
        som.fail(f"runuser -u bob -- ${pkgs.curl}/bin/curl -s -m 5 -H 'X-Forwarded-For: 1.2.3.4' http://{alice4}:14043/")
        # Every packet is gated, not only a flow's first: alice holds a UDP
        # flow to her slot's v4 from port 40000 with SO_REUSEADDR, which
        # lets bob bind the same port (no uid check for REUSEADDR) and send
        # on her established conntrack entry. The slot must not hear him.
        assert "ct state" not in som.succeed("nft list chain inet agent-slots output")
        grep = "${pkgs.gnugrep}/bin/grep"
        som.succeed(f"systemd-run --unit=a-udp4 {in_slot('alice')} ${pkgs.socat}/bin/socat UDP4-LISTEN:9999 SYSTEM:'${pkgs.coreutils}/bin/tee -a /root/udp.log'")
        som.succeed(f"systemd-run --unit=alice-udp --uid=alice ${pkgs.socat}/bin/socat UDP4:{alice4}:9999,sourceport=40000,reuseaddr SYSTEM:'echo alice; ${pkgs.coreutils}/bin/cat >/tmp/alice-udp.reply; true'")
        # the slot echoed: the flow is established both ways
        som.wait_until_succeeds(f"{grep} -qx alice /tmp/alice-udp.reply", timeout=30)
        som.execute(f"echo bob | runuser -u bob -- ${pkgs.socat}/bin/socat -u - UDP4-SENDTO:{alice4}:9999,sourceport=40000,reuseaddr")
        som.sleep(2)
        heard = som.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/cat /root/udp.log")
        assert heard.split() == ["alice"], heard
        som.succeed("systemctl stop alice-udp a-udp4 a-udp6")

    with subtest("a slot's own connections leave only through the egress link"):
        curl = in_slot("alice") + "${pkgs.curl}/bin/curl -s -m 5 -g "
        out = som.succeed(curl + "http://${clientIPv4}:8081/")
        assert "peer=${tunnelIPv4}" in out, out
        out = som.succeed(curl + "'http://[${clientIPv6}]:8081/'")
        assert peer(out) == "${tunnelIPv6}", out
        out = som.succeed("ip route get ${clientIPv4} from 10.43.4.2 iif ve-alice mark 0x2000000")
        assert "dev eth2" in out, out
        # Inbound keeps answering the way it came: v6 straight back over
        # br0 (down the tunnel the relay would drop it), forwarded v4 back
        # through wg-v4fwd.
        out = client.succeed("curl -g -s -m 10 'http://[" + alice6 + "]:8086/'")
        assert peer(out) == "${clientIPv6}", out
        out = client.succeed("curl -s -m 10 http://${publicIPv4}:14043/")
        assert "peer=${clientIPv4}" in out, out
        # kill switch: without the egress routes, nothing leaves another way
        som.succeed("ip route flush table ${toString egressTable}")
        som.succeed("ip -6 route flush table ${toString egressTable}")
        som.fail(curl + "http://${clientIPv4}:8081/")
        som.fail(curl + "'http://[${clientIPv6}]:8081/'")
        out = client.succeed("curl -g -s -m 10 'http://[" + alice6 + "]:8086/'")
        assert peer(out) == "${clientIPv6}", out
        som.succeed("ip route add default via ${relayIPv4} dev eth2 table ${toString egressTable}")
        som.succeed("ip -6 route add default via ${relayIPv6} dev eth2 table ${toString egressTable}")
        som.succeed(curl + "-f http://${clientIPv4}:8081/")
        som.succeed("systemctl stop a-any a-any6")

    with subtest("blocked destinations (the routers' WAN side) stay out of reach"):
        nc = in_slot("alice") + "${pkgs.netcat-openbsd}/bin/nc -z -w 5 "
        # routed down the egress link like any destination, then dropped
        out = som.succeed("ip route get ${routerWanIPv4} from 10.43.4.2 iif ve-alice mark 0x2000000")
        assert "dev eth2" in out, out
        som.succeed(nc + "${clientIPv4} 8081")
        som.fail(nc + "${routerWanIPv4} 8081")
        som.fail(nc + "${routerWanIPv6} 8081")

    with subtest("the return mark leaves the Mullvad app's mark alone"):
        som.succeed("ip rule | grep -q 'fwmark 0x10000000/0x10000000 lookup 51820'")
        out = som.succeed("ip route get ${clientIPv4} mark 0x6d6f6c65")
        assert "wg-v4fwd" not in out, out

    with subtest("the slots run in agent-slots.slice, under its limits"):
        assert som.succeed("systemctl show container@alice.service -p Slice --value").strip() == "agent-slots.slice"
        props = som.succeed("systemctl show agent-slots.slice -p MemoryMax -p MemoryHigh -p TasksMax -p IOWeight -p CPUWeight")
        for want in ["MemoryMax=12884901888", "MemoryHigh=10737418240", "TasksMax=8192", "IOWeight=20", "CPUWeight=20"]:
            assert want in props, props
        assert som.succeed("systemctl show container@alice.service -p TasksMax --value").strip() == "2048"
        som.succeed("machinectl status alice >/dev/null")

    with subtest("a slot cannot steer the host's start script through symlinks"):
        root = "/var/lib/nixos-containers/alice"
        som.succeed("install -d -m 0755 /srv/probe && install -d -m 0700 /var/lib/private")
        modes = lambda: som.succeed("stat -c '%n %a' / /root /var/lib /var/lib/private /srv/probe")
        before = modes()
        # the guest, as its root, swaps its /root for a link to /
        som.succeed(in_slot("alice") + "${pkgs.bash}/bin/sh -c 'rm -rf /root && ln -s / /root'")
        som.succeed("runuser -u alice -- slot stop")
        som.fail("runuser -u alice -- slot start")
        som.fail("systemctl is-active container@alice.service")
        som.succeed("journalctl -u container@alice --no-pager | grep -q '/root in the slot is a symlink'")
        assert modes() == before, (before, modes())
        # what it could plant just as well (set here from the host, the
        # slot being down): /var/lib/private -> a host directory
        som.succeed(f"rm {root}/root && mkdir -m 0700 {root}/root")
        som.succeed(f"rm -rf {root}/var/lib/private && ln -s /srv/probe {root}/var/lib/private")
        som.fail("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        som.succeed("journalctl -u container@alice --no-pager | grep -q '/var/lib/private in the slot is a symlink'")
        som.succeed(f"rm {root}/var/lib/private && mkdir -m 0700 {root}/var/lib/private")
        som.succeed(f"rm -rf {root}/var/lib && ln -s /var/lib/private {root}/var/lib")
        som.fail("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        som.succeed("journalctl -u container@alice --no-pager | grep -q ': /var/lib in the slot is a symlink'")
        assert modes() == before, (before, modes())
        # dangling links where the script touches or copies a file: removed,
        # the slot starts, nothing appears on the host
        som.succeed(f"rm {root}/var/lib && mkdir -m 0755 {root}/var/lib")
        som.succeed(f"ln -sfn /srv/nologin-probe {root}/etc/machine-id && ln -sfn /srv/probe/resolv {root}/etc/resolv.conf")
        som.succeed("systemctl reset-failed container@alice.service; systemctl start container@alice.service")
        som.succeed("test ! -e /srv/nologin-probe && test ! -e /srv/probe/resolv")
        som.succeed(f"test ! -L {root}/etc/machine-id && test ! -L {root}/etc/resolv.conf")
        assert modes() == before, (before, modes())
        # a machine-id link to a file that exists on the host goes too:
        # its target's existence is host state the agent can flip
        som.succeed("systemctl stop container@alice.service")
        som.succeed("echo keep > /srv/mid-probe && touch -d @1000000000 /srv/mid-probe")
        som.succeed(f"ln -sfn /srv/mid-probe {root}/etc/machine-id")
        som.succeed("systemctl start container@alice.service")
        som.succeed(f"test ! -L {root}/etc/machine-id")
        som.succeed("test \"$(stat -c %Y /srv/mid-probe)\" = 1000000000 && grep -qx keep /srv/mid-probe")
        # a NixOS guest's own /etc/os-release link does not stop it
        som.succeed(f"test -L {root}/etc/os-release")
        # The agent's way out is a hard reset, which also drops the gc
        # roots the guest made (through its bind of gcroots/per-container).
        som.succeed(in_slot("alice") + "${pkgs.coreutils}/bin/ln -s ${broken} /nix/var/nix/gcroots/pin")
        som.succeed("test -L /nix/var/nix/gcroots/per-container/alice/pin")
        som.succeed("runuser -u alice -- slot reset --hard")
        som.succeed("test ! -e /nix/var/nix/gcroots/per-container/alice/pin")
        som.succeed("systemctl is-active container@alice.service")
        som.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)

    with subtest("the desired state survives a reboot"):
        som.succeed("runuser -u bob -- slot stop")
        som.fail("systemctl is-active container@bob.service")
        # A stopped slot's addresses lead nowhere, not to the default
        # route or the LAN /64 (where any peer could claim the v6).
        som.fail(f"ip route get {bob4}")
        som.fail(f"ip -6 route get {bob6}")
        assert "dev ve-alice" in som.succeed(f"ip route get {alice4}")
        assert "dev ve-alice" in som.succeed(f"ip -6 route get {alice6}")
        som.fail(ssh_as("bob", bob4))
        # A power cut, not a clean shutdown: the state written by the
        # control units must already be on disk (and this VM's read-only
        # store image keeps a clean poweroff from ever finishing).
        som.crash()
        som.start()
        som.wait_for_unit("agent-slots-restore.service")
        som.wait_for_unit("container@alice.service")
        som.fail("systemctl is-active container@bob.service")
        assert "desired off" in som.succeed("runuser -u bob -- slot status")
        som.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)

    with subtest("a reset brings back a slot whose deploy dropped sshd"):
        # What a deploy of a system without sshd leaves behind: the slot's
        # profile on it, and the slot rebooted into it. Set from the host:
        # this VM's store is read-only, so nix inside the slot cannot.
        som.succeed("nix-env -p /nix/var/nix/profiles/per-container/alice/system --set ${broken}")
        som.succeed("systemctl restart container@alice.service")
        som.sleep(10)
        som.fail(ssh_as("alice", alice4))
        som.succeed("runuser -u alice -- slot reset")
        som.succeed("systemctl is-active container@alice.service")
        som.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        som.succeed(ssh_as("alice", alice4, "'touch /root/marker'"))
        som.succeed("journalctl -u agent-slot-reset@alice --no-pager | grep -q 'slot alice: reset, then back to on'")

    with subtest("a hard reset also wipes the slot, and keeps it off when it was off"):
        som.succeed("runuser -u alice -- slot reset --hard")
        som.wait_until_succeeds(ssh_as("alice", alice4), timeout=90)
        som.fail(ssh_as("alice", alice4, "'test -e /root/marker'"))
        som.succeed("runuser -u bob -- slot reset --hard")
        som.fail("systemctl is-active container@bob.service")
        assert "desired off" in som.succeed("runuser -u bob -- slot status")

    with subtest("control units are rate-limited"):
        # bob's earlier stop still counts: at most 6 in 10 minutes in all
        ok = 0
        while som.execute("runuser -u bob -- slot stop")[0] == 0:
            ok += 1
            assert ok <= 6, "no rate limit"
        assert ok >= 4, ok
        som.succeed("journalctl -u agent-slot-stop@bob --no-pager | grep -q 'stop refused, 6 already'")
        # per action: a start still goes through
        som.succeed("runuser -u bob -- slot start")
  '';
}
