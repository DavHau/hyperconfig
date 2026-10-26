# The publish module in local mode, end to end, on one machine: dex (the
# sso module's local issuer) with three accounts, alice and bob owning one
# agent each and carol none, and echo apps standing in for what alice
# publishes (hermes itself does not run: its units are off). Everything is
# reached the way a browser on the host does, at
# http://<port>.<agent>.hermes.localhost:8473/.
#
# Checks:
# - alice signs in on her private port (its own login, dex's form) and
#   gets her app; the login cookie is host-only, so her next port signs in
#   again on its own host; the post-login redirect stays on the host,
# - bob, signed in, gets 403 on alice's port; his session copied to her
#   host does not open it; carol, in no agent's group, is refused by the
#   login itself (dex admits everyone: the proxy's group check),
# - a public port needs no login; a port under the wrong agent's name is
#   no server,
# - no login cookie reaches an app; apps set cookies on their own host
#   only; Origin and the forwarded headers as the skill promises; the
#   Fetch Metadata gate on private ports,
# - bypassing the proxy: another agent cannot dial alice's ports, the
#   sockets nginx dials, or the login's socket; a squatter on alice's port
#   gets nothing and the visitor gets 502,
# - the rendered skill shows the local URLs and the port table; no ACME
#   certificate and no DNS record in local mode.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  domain = "hermes.localhost";
  port = 8473;
  secrets = "/var/lib/publish-secrets";
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.requests
  ]);
  # uid 1001: 30010-30014 private, 30015-30019 public; uid 1002: 30020-.
  alicePrivate = 30010;
  alicePrivate2 = 30011;
  alicePublic = 30015;
  bobPrivate = 30020;
  urlOf = p: agent: "http://${toString p}.${agent}.${domain}:${toString port}";
  echoPorts = [
    alicePrivate
    alicePrivate2
    alicePublic
  ];
in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  {
    name = "hyperhermes-publish";

    nodes.machine = {
      imports = [ self.nixosModules.default ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        pkgs.curl
        python
      ];

      services.hyperhermes = {
        pythonPackages = _: [ ];
        agents = {
          alice.uid = 1001;
          bob.uid = 1002;
        };
        exposure.enable = true;
        sso = {
          enable = true;
          accounts = {
            alice = "alice";
            bob = "bob";
          };
          clients = lib.genAttrs [ "hermes-alice" "hermes-bob" "hermes-serve" ] (id: {
            secretFile = "${secrets}/${id}";
          });
          dex.users = lib.genAttrs [ "alice" "bob" "carol" ] (account: {
            passwordHashFile = "${secrets}/${account}.hash";
          });
        };
        dashboards.enable = true;
        publish = {
          enable = true;
          cookieSecretFile = "${secrets}/serve-cookie";
        };
      };
      # The agents' own units are not under test.
      systemd.services = lib.mkMerge [
        (lib.genAttrs (lib.concatMap (agent: [
          "hermes-agent-${agent}"
          "hermes-dashboard-${agent}"
          "hermes-python-venv-${agent}"
        ]) [ "alice" "bob" ]) (_: { enable = false; }))

        # alice's apps.
        (lib.listToAttrs (
          map (
            p:
            lib.nameValuePair "echo-${toString p}" {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                User = "alice";
                ExecStart = "${pkgs.python3}/bin/python3 ${./echo.py} ${toString p} /run/echo-${toString p}/log";
                RuntimeDirectory = "echo-${toString p}";
                RuntimeDirectoryMode = "0755";
                RuntimeDirectoryPreserve = true;
              };
            }
          ) echoPorts
        ))

        {
          # Stand-ins for the deployment's secrets, created at runtime.
          publish-secrets = {
            wantedBy = [ "multi-user.target" ];
            requiredBy = [
              "dex.service"
              "oauth2-proxy-serve.service"
            ];
            before = [
              "dex.service"
              "oauth2-proxy-serve.service"
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              install -d -m 700 ${secrets}
              for id in hermes-alice hermes-bob hermes-serve; do
                echo -n "client-secret-$id" > ${secrets}/$id
              done
              echo -n 0123456789abcdef0123456789abcdef > ${secrets}/serve-cookie
              for user in alice bob carol; do
                ${python}/bin/python3 -c "import bcrypt; print(bcrypt.hashpw(b'$user-password', bcrypt.gensalt(10)).decode())" \
                  > ${secrets}/$user.hash
              done
            '';
          };
          # Discovery needs dex up.
          oauth2-proxy-serve.after = [ "dex.service" ];
        }
      ];
    };

    testScript = ''
      import json

      skill_dirs = ${builtins.toJSON nodes.machine.services.hyperhermes.skillDirs}
      certs = ${builtins.toJSON (lib.attrNames nodes.machine.security.acme.certs)}
      dns_records = ${builtins.toJSON nodes.machine.services.hyperhermes.exposure.dnsRecords}

      def curl(url, *opts):
          """(status, body) of one request, not followed."""
          out = machine.succeed(f"curl -s -o /tmp/body -w '%{{http_code}}' {' '.join(opts)} '{url}'")
          return out, machine.succeed("cat /tmp/body")

      def location(url, *opts):
          out = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}} %{{redirect_url}}' {' '.join(opts)} '{url}'")
          code, _, loc = out.partition(" ")
          return code, loc

      def echo_log(p):
          return [json.loads(l) for l in machine.succeed(f"cat /run/echo-{p}/log").splitlines()]

      def serve(url, account, expect):
          out = machine.succeed(
              f"${python}/bin/python3 ${./serve.py} {url} {account}@${domain} {account}-password {expect}"
          )
          print(out)
          return json.loads(out.strip().splitlines()[-1])

      start_all()
      machine.wait_for_unit("dex.service")
      machine.wait_for_unit("nginx.service")
      for p in (${toString alicePrivate}, ${toString alicePrivate2}, ${toString alicePublic}):
          machine.wait_for_unit(f"echo-{p}.service")
          machine.wait_for_open_port(p)
      machine.wait_until_succeeds("curl -sf -o /dev/null --unix-socket /run/oauth2-proxy-serve.sock http://localhost/ping", timeout=120)

      with subtest("alice signs in on her private port and gets her app"):
          alice = serve("${urlOf alicePrivate "alice"}/p?x=1", "alice", "ok")
          session = alice["_hermes_serve"]
          seen = [e for e in echo_log(${toString alicePrivate}) if e["path"] == "/p?x=1"][-1]
          print(seen)
          assert seen["host"] == "127.0.0.1:${toString alicePrivate}", seen
          assert seen["forwarded_host"] == "${toString alicePrivate}.alice.${domain}:${toString port}", seen
          assert seen["forwarded_proto"] == "http", seen
          assert not any("_hermes_serve" in c for c in seen["cookie"]), seen

      with subtest("the login is per host; its redirect stays on the host"):
          # (the browser sends the host-only cookie of the first port nowhere else)
          code, loc = location("${urlOf alicePrivate2 "alice"}/")
          assert code == "302" and loc.startswith("http://localhost:${toString port}/auth?"), (code, loc)
          assert "redirect_uri=http%3A%2F%2F${toString alicePrivate2}.alice.${domain}%3A${toString port}%2F.hermes-serve-login%2Fcallback" in loc, loc
          code, loc = location("${urlOf alicePrivate "alice"}/.hermes-serve-login/start?rd=https://evil.example/")
          assert code == "302" and "evil.example" not in loc, (code, loc)
          # oauth2-proxy-serve: callback from the request's host, no cookie
          # domain, no redirect beyond it, no TCP listener.
          cat = machine.succeed("systemctl cat oauth2-proxy-serve")
          for flag in ("--redirect-url", "--cookie-domain", "--whitelist-domain"):
              assert flag not in cat, (flag, cat)
          listen = machine.succeed("ss -Hltn | awk '{print $4}'").split()
          assert not any(a.endswith((":4180", ":4181", ":4182")) for a in listen), listen

      with subtest("bob gets 403 on alice's port; carol is refused by the login"):
          bob = serve("${urlOf alicePrivate "alice"}/", "bob", "forbidden")
          # bob's session replayed on alice's other port: still bob.
          code, body = curl("${urlOf alicePrivate2 "alice"}/", f"-H 'Cookie: _hermes_serve={bob['_hermes_serve']}'")
          assert code == "403" and "Not published" in body, (code, body)
          # alice's own session, replayed on bob's host: still her account.
          code, body = curl("${urlOf bobPrivate "bob"}/", f"-H 'Cookie: _hermes_serve={session}'")
          assert code == "403" and "Not published" in body, (code, body)
          serve("${urlOf alicePrivate "alice"}/", "carol", "refused")

      with subtest("public port without login; wrong agent's name is no server"):
          code, body = curl("${urlOf alicePublic "alice"}/pub")
          assert code == "200" and body == "backend ${toString alicePublic}\n", (code, body)
          assert curl("${urlOf alicePrivate "bob"}/")[0] == "404"
          assert curl("${urlOf alicePublic "bob"}/")[0] == "404"

      with subtest("no login cookie reaches an app; cookies stay on the port host"):
          cookies = "_hermes_serve_csrf=x; app=1; trader=tok; _xsrf=abc; __Host-hermes=f; hermes=front; _hermes_serve=" + session
          for p, url in ((${toString alicePrivate}, "${urlOf alicePrivate "alice"}/leak"), (${toString alicePublic}, "${urlOf alicePublic "alice"}/leak")):
              code, _ = curl(url, f"-H 'Cookie: {cookies}'")
              assert code == "200", (url, code)
              got = [e for e in echo_log(p) if e["path"] == "/leak"][-1]["cookie"]
              print(p, got)
              assert got == ["app=1; trader=tok; _xsrf=abc; hermes=front"], (url, got)
          hdrs = machine.succeed("curl -s -D - -o /dev/null ${urlOf alicePublic "alice"}/")
          assert "planted=1; Domain=${toString alicePublic}.alice.${domain};" in hdrs, hdrs

      with subtest("Origin: the page's own becomes the app's loopback origin"):
          for origin, seen in (("${urlOf alicePublic "alice"}", "http://127.0.0.1:${toString alicePublic}"),
                               ("http://${toString alicePublic}.alice.${domain}", "http://${toString alicePublic}.alice.${domain}"),
                               ("${urlOf alicePrivate "alice"}", "${urlOf alicePrivate "alice"}"),
                               ("https://evil.example", "https://evil.example"),
                               (None, None)):
              curl("${urlOf alicePublic "alice"}/origin", *([f"-H 'Origin: {origin}'"] if origin else []))
              e = [e for e in echo_log(${toString alicePublic}) if e["path"] == "/origin"][-1]
              assert e["origin"] == seen and e["host"] == "127.0.0.1:${toString alicePublic}", (origin, e)

      with subtest("Fetch Metadata: other origins only navigate to a private port"):
          nav = ["Sec-Fetch-Mode: navigate", "Sec-Fetch-Dest: document"]
          def fm(url, site, extra, method="GET"):
              hs = ([f"Sec-Fetch-Site: {site}"] if site else []) + extra
              return curl(url, f"-H 'Cookie: _hermes_serve={session}'", f"-X {method}", *[f"-H '{h}'" for h in hs])[0]
          url = "${urlOf alicePrivate "alice"}/fm"
          for site in ("cross-site", "same-site"):
              assert fm(url, site, nav, "POST") == "403", site
              assert fm(url, site, ["Sec-Fetch-Mode: cors", "Sec-Fetch-Dest: empty"]) == "403", site
              assert fm(url, site, ["Sec-Fetch-Mode: websocket", "Sec-Fetch-Dest: websocket"]) == "403", site
              assert fm(url, site, nav) == "200", site
          assert fm(url, "same-origin", ["Sec-Fetch-Mode: cors", "Sec-Fetch-Dest: empty"], "POST") == "200"
          assert fm("${urlOf alicePublic "alice"}/fm", "cross-site", ["Sec-Fetch-Mode: cors", "Sec-Fetch-Dest: empty"]) == "200"

      with subtest("no way around the proxy for another uid"):
          for p in (${toString alicePrivate}, ${toString alicePublic}):
              machine.succeed(f"runuser -u alice -- curl -sf -o /dev/null http://127.0.0.1:{p}/direct")
              machine.succeed(f"curl -sf -o /dev/null http://127.0.0.1:{p}/direct")
              machine.fail(f"runuser -u bob -- curl -s --max-time 5 -o /dev/null http://127.0.0.1:{p}/bypass")
              sock = f"/run/hermes-serve/{p}.sock"
              assert machine.succeed(f"stat -c '%U:%G %a' {sock}").strip() == "root:nginx 660", sock
              machine.fail(f"runuser -u bob -- curl -s --max-time 5 -o /dev/null --unix-socket {sock} http://x/bypass")
          sock = "/run/oauth2-proxy-serve.sock"
          assert machine.succeed(f"stat -c '%U:%G %a' {sock}").strip() == "root:nginx 660", sock
          machine.fail(f"runuser -u bob -- curl -s --max-time 5 -o /dev/null --unix-socket {sock} http://x/ping")
          assert not any(e["path"] == "/bypass" for p in (${toString alicePrivate}, ${toString alicePublic}) for e in echo_log(p))

      with subtest("a squatter on alice's port: 502, and it sees nothing"):
          machine.succeed("systemctl stop echo-${toString alicePrivate} echo-${toString alicePublic}")
          for p in (${toString alicePrivate}, ${toString alicePublic}):
              machine.succeed(f"systemd-run --uid=bob --unit=squat-{p} -p RuntimeDirectory=squat-{p} ${pkgs.python3}/bin/python3 ${./echo.py} {p} /run/squat-{p}/log squatter")
              machine.wait_until_succeeds(f"curl -sf -o /dev/null http://127.0.0.1:{p}/self && rm -f /run/squat-{p}/log")
          code, body = curl("${urlOf alicePrivate "alice"}/squat", f"-H 'Cookie: _hermes_serve={session}'")
          assert code == "502" and "squatter" not in body, (code, body)
          code, body = curl("${urlOf alicePublic "alice"}/squat")
          assert code == "502" and "squatter" not in body, (code, body)
          for p in (${toString alicePrivate}, ${toString alicePublic}):
              machine.fail(f"test -s /run/squat-{p}/log")
              machine.wait_until_succeeds(f"journalctl -u 'hermes-serve-fwd-{p}@*' | grep -q 'owned by uid 1002'")
          failed = machine.succeed("systemctl list-units --failed --all --plain --no-legend 'hermes-serve-fwd-*'")
          assert failed.strip() == "", failed
          machine.succeed("systemctl stop squat-${toString alicePrivate} squat-${toString alicePublic}")
          machine.succeed("systemctl start echo-${toString alicePrivate} echo-${toString alicePublic}")
          machine.wait_for_open_port(${toString alicePrivate})
          machine.wait_for_open_port(${toString alicePublic})
          code, body = curl("${urlOf alicePrivate "alice"}/back", f"-H 'Cookie: _hermes_serve={session}'")
          assert code == "200" and body == "backend ${toString alicePrivate}\n", (code, body)

      with subtest("the skill shows the local URLs; nothing public"):
          skill = machine.succeed(" ".join(["cat"] + [f"$(ls {d}/serve-ports/SKILL.md 2>/dev/null)" for d in skill_dirs]))
          print(skill)
          assert "http://<port>.<account>.${domain}:${toString port}/" in skill, skill
          assert "| alice | 30010, 30011, 30012, 30013, 30014 | 30015, 30016, 30017, 30018, 30019 |" in skill, skill
          assert "| bob | 30020, 30021, 30022, 30023, 30024 | 30025, 30026, 30027, 30028, 30029 |" in skill, skill
          assert "https" not in skill and "TLS" not in skill, skill
          assert certs == [] and dns_records == [], (certs, dns_records)
    '';
  }
)
