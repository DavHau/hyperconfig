# ./service.nix with ../mullvad-egress (as ./default.nix wires it on som)
# against a fake Mullvad relay that also plays the internet: a site
# (45.0.0.10, answers with the client address it saw) and a fake provider
# (./test-provider.py, TLS on provider.example = 45.0.0.20:1001).
#
#   - alice (a client, Mullvad-tunneled like som's agents) reaches the site
#     directly through the tunnel by default (10.64.0.2), and through the
#     gateway only on request (curl -x, and web_extract's fetch.py with a
#     country): then the provider dials it (the site sees 45.0.0.10), with
#     the country/session she picked and the gateway's credentials;
#   - the gateway reaches the provider only through the tunnel (the
#     provider logs 10.64.0.2), and nothing else on loopback;
#   - mallory (not a client) is refused at the port; neither reads the
#     credentials (files, the unit's credentials, its environment);
#   - a bad proxy username, a non-public target (loopback, private,
#     link-local, CGNAT, mesh, any IP spelling, internal names) or a port
#     other than 80/443 is refused before anything reaches the provider;
#   - the provider's refusal text never reaches the client;
#   - one client uid holds at most connectionsPerClient connections;
#   - traffic used up (the provider's 402): a clear 402 from the gateway,
#     and fetch.py says so (kind proxy_exhausted).
{ pkgs }:
let
  inherit (pkgs) lib;
  clientKey = pkgs.writeText "client.key" "oDo351gr0UPzU4ex3TzYbnJCvCDP5TGQMxnLUsPr0mo=";
  clientPub = "cPO7htK35VbRGFJsVIomGX9hau09HpGGgNdv7SBbKTw=";
  relayKey = pkgs.writeText "relay.key" "EJI6HBbdnope4OYeIWH24MLGfOYkxPe9cRzaZHmG40E=";
  relayPub = "brG6NaMb5h/iC8RwTcGQ7sXKr6kL9N0gaPUOnrZisgI=";

  tls = pkgs.runCommand "residential-proxy-test-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj /CN=test-ca -keyout ca.key -out $out/ca.pem \
      -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -subj /CN=provider.example -keyout $out/key.pem -out req.csr
    printf 'subjectAltName=DNS:provider.example\nbasicConstraints=CA:FALSE\n' > ext
    openssl x509 -req -in req.csr -CA $out/ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext -out $out/cert.pem
  '';

  # web_extract's worker as the plugin runs it (hyperhermes
  # modules/browser/web-extract.nix), minus the browser retry's Camoufox.
  extractPython = pkgs.python3.withPackages (ps: [
    ps.curl-cffi
    ps.trafilatura
  ]);
  fetchPy = ../../../hyperhermes/modules/browser/web-extract/fetch.py;

  # Raw requests to the gateway as sg:, which curl cannot send verbatim:
  #   connect <host:port>  CONNECT exactly that, print the status line
  #   cr                   a GET with a lone CR in its path
  #   hold <n>             open n connections, touch /tmp/held, wait
  probe = pkgs.writeText "probe.py" ''
    import signal, socket, sys

    AUTH = b"Proxy-Authorization: Basic c2c6\r\n"  # sg:


    def ask(raw):
        s = socket.create_connection(("127.0.0.1", 8897), timeout=10)
        s.sendall(raw)
        print(s.recv(200).split(b"\r\n")[0].decode())


    if sys.argv[1] == "connect":
        t = sys.argv[2].encode()
        ask(b"CONNECT " + t + b" HTTP/1.1\r\nHost: " + t + b"\r\n" + AUTH + b"\r\n")
    elif sys.argv[1] == "cr":
        ask(b"GET http://site.example/a\rX HTTP/1.1\r\n" + AUTH + b"\r\n")
    elif sys.argv[1] == "hold":
        held = [socket.create_connection(("127.0.0.1", 8897)) for _ in range(int(sys.argv[2]))]
        open("/tmp/held", "w").close()
        signal.pause()
  '';
in
pkgs.testers.runNixOSTest {
  name = "residential-proxy";
  globalTimeout = 900;

  containers.relay = {
    networking.firewall.enable = false;
    # the provider resolves the targets itself, as Evomi's would
    networking.hosts."45.0.0.10" = [
      "site.example"
      "echo.example"
    ];
    networking.wireguard.interfaces.wg0 = {
      ips = [
        "10.64.0.1/32"
        "45.0.0.10/32"
        "45.0.0.20/32"
        "192.0.2.2/32"
      ];
      listenPort = 51820;
      privateKeyFile = "${relayKey}";
      peers = [
        {
          publicKey = clientPub;
          allowedIPs = [ "10.64.0.2/32" ];
        }
      ];
    };
    # The site: who connected.
    services.nginx = {
      enable = true;
      virtualHosts.site = {
        default = true;
        listen = [
          {
            addr = "45.0.0.10";
            port = 80;
          }
        ];
        locations."/".return = ''200 "<html><body><p>site saw $remote_addr</p></body></html>\n"'';
        extraConfig = "default_type text/html;";
      };
    };
    systemd.services.provider = {
      wantedBy = [ "multi-user.target" ];
      after = [ "wireguard-wg0.service" ];
      requires = [ "wireguard-wg0.service" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${./test-provider.py} ${tls}/cert.pem ${tls}/key.pem 45.0.0.20 1001";
    };
  };

  containers.client =
    { config, ... }:
    {
      imports = [
        ../../../hyperhermes/checks/container-pam.nix
        ../mullvad-egress/egress.nix
        ../mullvad-egress/dns.nix
        ./service.nix
      ];

      networking.useNetworkd = true;
      networking.nftables.enable = true;
      networking.defaultGateway = {
        address = "192.168.1.2";
        interface = "eth1";
      };
      boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 1;
      services.resolved.enable = true;
      networking.useHostResolvConf = false;
      networking.nameservers = [ "192.168.1.2" ];
      networking.hosts."45.0.0.20" = [ "provider.example" ];
      networking.hosts."45.0.0.10" = [ "site.example" ];

      users.users.alice = {
        isNormalUser = true;
        uid = 1001;
      };
      users.users.mallory = {
        isNormalUser = true;
        uid = 1002;
      };

      hyper.residentialProxy = {
        enable = true;
        uid = 1222;
        clients = [ "alice" ];
        connectionsPerClient = 4;
        upstream = {
          host = "provider.example";
          port = 1001;
          caFile = "${tls}/ca.pem";
        };
        userFile = "/etc/test-vars/evomi-proxy/user";
        passwordFile = "/etc/test-vars/evomi-proxy/password";
      };
      environment.etc."test-vars/evomi-proxy/user" = {
        text = "evomi-user";
        mode = "0400";
      };
      environment.etc."test-vars/evomi-proxy/password" = {
        text = "evomi-pass";
        mode = "0400";
      };

      # As on som: the agents and the gateway leave only through Mullvad,
      # the gateway reaching nothing on loopback but its own listener.
      hyper.mullvadEgress = {
        users = [
          "alice"
          "residential-proxy"
        ];
        dns.services = [ "residential-proxy" ];
        tunnelOnly.residential-proxy = [ "127.0.0.1:${toString config.hyper.residentialProxy.port}" ];
        addresses = [ "10.64.0.2/32" ];
        privateKeyFile = "${clientKey}";
        relays = [
          {
            endpoint = "192.0.2.2:51820";
            publicKey = relayPub;
          }
        ];
      };
      systemd.timers.mullvad-egress-failover.enable = false;

      # A loopback service the gateway must not reach.
      services.nginx = {
        enable = true;
        virtualHosts.local = {
          listen = [
            {
              addr = "127.0.0.1";
              port = 8080;
            }
          ];
          locations."/".return = ''200 "local\n"'';
        };
      };

      environment.systemPackages = [
        pkgs.curl
        extractPython
      ];
    };

  testScript = ''
    import json

    def run(user, cmd):
        return client.execute(f"runuser -u {user} -- {cmd} 2>&1")

    def curl(user, args):
        rc, out = run(user, f"curl -sS --max-time 20 {args}")
        return rc, out.strip()

    def extract(user, url, country=None):
        env = "env HOME=/tmp RESIDENTIAL_PROXY_URL=http://127.0.0.1:8897"
        tail = f" markdown {country}" if country else ""
        rc, out = run(user, f"{env} ${extractPython}/bin/python3 ${fetchPy} {url}{tail}")
        try:
            return json.loads(out.splitlines()[-1])
        except Exception:
            raise AssertionError(f"fetch.py: {rc} {out}")

    def provider_log():
        return relay.succeed("cat /tmp/provider.log 2>/dev/null || true").split("\n")

    start_all()
    relay.wait_for_unit("wireguard-wg0.service", timeout=120)
    relay.wait_for_unit("provider.service", timeout=120)
    relay.wait_for_unit("nginx.service", timeout=120)
    client.wait_until_succeeds("ip route show table 51830 | grep -q 'default dev wg-mullvad'", timeout=90)
    client.wait_for_unit("residential-proxy.service", timeout=120)
    client.wait_until_succeeds("ss -ltn | grep -q '127.0.0.1:8897 '", timeout=60)

    with subtest("default: alice's traffic goes direct through the tunnel, not the proxy"):
        rc, out = curl("alice", "http://site.example/")
        assert rc == 0 and "site saw 10.64.0.2" in out, out
        r = extract("alice", "http://site.example/")
        assert "10.64.0.2" in r.get("content", ""), r
        assert provider_log() == [""], provider_log()

    with subtest("on request: through the gateway, the provider dials the site"):
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U us: http://site.example/")
        assert rc == 0 and "site saw 45.0.0.10" in out, out
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U de-session-ab12cd34: http://site.example/")
        assert rc == 0 and "site saw 45.0.0.10" in out, out
        # no username at all: a Basic challenge (browsers answer it), not a
        # silent default
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -o /dev/null -w '%{http_code}' http://site.example/")
        assert out.endswith("407"), out
        log = provider_log()
        # the gateway reached the provider through the tunnel, with its
        # credentials and alice's targeting
        assert "10.64.0.2 US - site.example:80" in log, log
        assert "10.64.0.2 DE ab12cd34 site.example:80" in log, log

    with subtest("web_extract's fetch.py with a country goes through the gateway"):
        r = extract("alice", "http://site.example/", "jp")
        assert "45.0.0.10" in r.get("content", ""), r
        assert "10.64.0.2 JP - site.example:80" in provider_log(), provider_log()
        # with a task's session id (web_extract_residential passes one per
        # task): a sticky exit, so parallel subagents keep separate IPs
        r = extract("alice", "http://site.example/", "jp abc123def0")
        assert "45.0.0.10" in r.get("content", ""), r
        assert "10.64.0.2 JP abc123def0 site.example:80" in provider_log(), provider_log()

    with subtest("bad usernames are refused before the provider"):
        before = len(provider_log())
        for u in ["usa", "us_country-DE", "us-session-x", "us-session-abcdefghijk", "x:y"]:
            rc, out = curl("alice", f"-x http://127.0.0.1:8897 -U '{u}:' -o /dev/null -w '%{{http_code}}' http://site.example/")
            assert out.endswith("400"), (u, out)
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: -o /dev/null -w '%{http_code}' http://site.example:22/")
        assert out.endswith("403"), out
        assert len(provider_log()) == before, provider_log()

    with subtest("non-public targets and other ports are refused before the provider"):
        before = len(provider_log())
        # raw CONNECTs: curl would normalise the IP spellings itself
        for t in ["127.0.0.1:443", "10.0.0.1:443", "192.168.1.1:443", "100.64.0.1:443",
                  "169.254.169.254:80", "[::1]:443", "[::ffff:10.0.0.1]:443", "[fd00::1]:443",
                  "[fe80::1]:443", "[64:ff9b::a00:1]:443", "[200::1]:443", "0x7f000001:443",
                  "2130706433:443", "0177.0.0.1:443", "127.1:443", "localhost:443",
                  "localhost.:443", "router:443", "nas.d:443", "printer.local:443",
                  "10.0.0.08:443", "fritz.box:443", "[::ffff:0:a00:1]:443", "[::1]x:443",
                  "site.example:8080", "site.example:8443", "site.example:25"]:
            rc, out = run("alice", f"python3 ${probe} connect '{t}'")
            assert " 403 " in out or (t.endswith("x:443") and " 400 " in out), (t, out)
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: -o /dev/null -w '%{http_code}' http://169.254.169.254/latest")
        assert out.endswith("403"), out
        # a lone CR in the request line is refused, not forwarded
        rc, out = run("alice", "python3 ${probe} cr")
        assert " 400 " in out, out
        assert len(provider_log()) == before, provider_log()

    with subtest("the provider's refusal text never reaches the client"):
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: -i http://echo.example/")
        assert "502" in out.splitlines()[0] and "HTTP 403" in out, out
        assert "evomi" not in out, out
        journal = client.succeed("journalctl -u residential-proxy -o cat")
        assert "evomi-pass" not in journal and "evomi-user" not in journal, journal

    with subtest("one client holds at most connectionsPerClient connections"):
        client.succeed("rm -f /tmp/held; runuser -u alice -- setsid python3 ${probe} hold 4 >/dev/null 2>&1 &")
        client.wait_until_succeeds("test -e /tmp/held", timeout=20)
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: http://site.example/")
        assert rc != 0 and "site saw" not in out, out
        client.succeed("pkill -u alice -f 'probe.py hold' || true")
        # closed connections leave the count
        client.wait_until_succeeds("runuser -u alice -- curl -sS --max-time 10 -x http://127.0.0.1:8897 -U sg: http://site.example/ | grep -q 'site saw 45.0.0.10'", timeout=60)

    with subtest("only clients reach the gateway"):
        rc, out = curl("mallory", "-x http://127.0.0.1:8897 -U sg: http://site.example/")
        assert rc != 0 and "site saw" not in out, out

    with subtest("credentials are not readable by clients"):
        for user in ["alice", "mallory"]:
            assert run(user, "cat /etc/test-vars/evomi-proxy/password")[0] != 0
            assert run(user, "cat /run/credentials/residential-proxy.service/password")[0] != 0
            pid = client.succeed("systemctl show -p MainPID --value residential-proxy").strip()
            assert run(user, f"cat /proc/{pid}/environ")[0] != 0
        env = client.succeed("systemctl show -p Environment residential-proxy")
        assert "evomi-pass" not in env and "evomi-user" not in env, env
        # nor sent back: the client's view of a proxied answer
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: -i http://site.example/")
        assert "evomi" not in out, out

    with subtest("the gateway's own egress: only the tunnel, no loopback service"):
        rc = client.execute("runuser -u residential-proxy -- curl -sS --max-time 3 http://127.0.0.1:8080/")[0]
        assert rc != 0, "the gateway's uid reached a loopback service"
        # its traffic leaves through the tunnel (the site sees the tunnel
        # address); this probes the nft uid layer, not the unit's cgroup
        out = client.succeed("runuser -u residential-proxy -- curl -sS --max-time 5 http://site.example/").strip()
        assert "10.64.0.2" in out, out

    with subtest("traffic used up: a clear 402"):
        relay.succeed("touch /tmp/exhausted")
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: -i http://site.example/")
        assert "402" in out.splitlines()[0] and "used up" in out, out
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: https://site.example/")
        assert rc != 0, out
        r = extract("alice", "https://site.example/", "sg")
        assert r.get("kind") == "proxy_exhausted" and "used up" in r.get("error", ""), r
        relay.succeed("rm /tmp/exhausted")
        rc, out = curl("alice", "-x http://127.0.0.1:8897 -U sg: http://site.example/")
        assert "site saw 45.0.0.10" in out, out
  '';
}
