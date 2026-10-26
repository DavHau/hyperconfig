# Local mode end to end: a NixOS container (private network) runs the
# exposure + sso + dashboards modules and one agent's hermes dashboard; the
# host forwards its loopback port 8473 into the container, the way a
# workstation runs the local deployment. From the host, a scripted browser
# (./login.py) signs in at dex's password form and ends on an
# authenticated dashboard API call; a second dex account that owns no
# agent is refused at the same dashboard (dex itself admits it: the group
# check is hermes', core's allowed-groups patch). The app's sign-in
# (/auth/native/*) the same way: dex asked for a fresh login, the one-time
# code redeemed for bearer tokens that call the API and refresh; bob gets
# no code.
#
# It also pins the facts the modules rely on:
# - *.localhost resolves to loopback through nss-myhostname, on the host
#   and inside the container, so one URL works on both sides;
# - hermes refuses a plain-HTTP issuer under *.localhost (why dex sits at
#   http://localhost, ../../modules/sso.nix);
# - dex's static users' groups reach hermes' session.
{
  pkgs,
  self,
  hermesPackage,
}:
let
  domain = "hermes.localhost";
  port = 8473;
  containerAddress = "10.233.1.2";
  secrets = "/var/lib/local-sso-secrets";
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.requests
  ]);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-local-sso";

  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;

    # Socket-activated forward from the host's loopback into the
    # container: the host reaches the same URLs the container serves.
    systemd.sockets.hermes-forward = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [
        "127.0.0.1:${toString port}"
        "[::1]:${toString port}"
      ];
    };
    systemd.services.hermes-forward = {
      requires = [ "container@hh.service" ];
      after = [ "container@hh.service" ];
      serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${containerAddress}:${toString port}";
    };

    environment.systemPackages = [ pkgs.curl ];

    containers.hh = {
      autoStart = true;
      privateNetwork = true;
      hostAddress = "10.233.1.1";
      localAddress = containerAddress;
      config = {
        imports = [ self.nixosModules.default ];
        system.stateVersion = "26.05";
        networking.firewall.allowedTCPPorts = [ port ];
        environment.systemPackages = [
          hermesPackage
          pkgs.curl
        ];

        services.hyperhermes = {
          package = hermesPackage;
          pythonPackages = _: [ ];
          agents.alice.uid = 1001;
          exposure = {
            enable = true;
            listenAddresses = [
              "0.0.0.0"
              "[::]"
            ];
          };
          sso = {
            enable = true;
            accounts.alice = "alice";
            clients.hermes-alice.secretFile = "${secrets}/hermes-alice";
            dex.users.alice.passwordHashFile = "${secrets}/alice.hash";
            # Owns no agent: dex signs it in to any client.
            dex.users.bob.passwordHashFile = "${secrets}/bob.hash";
          };
          dashboards.enable = true;
        };

        # Stand-ins for the deployment's secrets, created at runtime.
        systemd.services.local-sso-secrets = {
          wantedBy = [ "multi-user.target" ];
          before = [
            "dex.service"
            "hermes-agent-alice.service"
          ];
          requiredBy = [
            "dex.service"
            "hermes-agent-alice.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 700 ${secrets}
            echo client-secret-alice > ${secrets}/hermes-alice
            for user in alice bob; do
              ${python}/bin/python3 -c "import bcrypt; print(bcrypt.hashpw(b'$user-password', bcrypt.gensalt(10)).decode())" \
                > ${secrets}/$user.hash
            done
          '';
        };

        systemd.services.hermes-dashboard-alice.after = [
          "dex.service"
          "nginx.service"
        ];
      };
    };
  };

  testScript = ''
    import json
    import re

    def inside(cmd):
        return machine.succeed(f"nixos-container run hh -- {cmd}")

    start_all()
    machine.wait_for_unit("container@hh.service")
    machine.wait_until_succeeds(
        "nixos-container run hh -- systemctl is-active dex.service nginx.service hermes-dashboard-alice.service"
    )

    with subtest("*.localhost is loopback on the host and inside the container"):
        for where, run in (("host", machine.succeed), ("container", inside)):
            hosts = run("getent ahosts alice.${domain}")
            print(where, hosts)
            assert "127.0.0.1" in hosts and "::1" in hosts, hosts
            nss = run("grep ^hosts: /etc/nsswitch.conf")
            assert "myhostname" in nss, nss

    with subtest("the issuer answers on the host (forward) and in the container (own nginx)"):
        for where, run in (("host", machine.wait_until_succeeds), ("container", lambda cmd: machine.wait_until_succeeds(f"nixos-container run hh -- {cmd}"))):
            disco = json.loads(run("curl -sf http://localhost:${toString port}/.well-known/openid-configuration"))
            assert disco["issuer"] == "http://localhost:${toString port}", disco
            assert "groups" in disco["scopes_supported"], disco

    with subtest("dashboard host routes to the container's hermes on both sides"):
        machine.wait_until_succeeds("curl -sf http://alice.${domain}:${toString port}/api/status")
        # Not curl's own *.localhost shortcut: the name glibc resolves
        # inside the container is its own nginx.
        inside("${python}/bin/python3 -c 'import urllib.request; print(urllib.request.urlopen(\"http://alice.${domain}:${toString port}/api/status\").read())'")
        machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://nothing.${domain}:${toString port}/ | grep -x 404")

    with subtest("hermes refuses a plain-HTTP issuer under *.localhost"):
        # Bounded: should hermes ever accept the issuer, the dashboard
        # would serve instead of exiting.
        status, out = machine.execute(
            "nixos-container run hh -- timeout 60 env HERMES_HOME=/tmp/refuse "
            "HERMES_DASHBOARD_PUBLIC_URL=http://bob.${domain}:${toString port} "
            "HERMES_DASHBOARD_OIDC_ISSUER=http://id.${domain}:${toString port} "
            "HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-bob "
            # The package itself: `hermes` on PATH is core's per-agent shim.
            "${hermesPackage}/bin/hermes dashboard --no-open --host 127.0.0.1 --port 9200 2>&1",
            timeout=120,
        )
        print(out)
        assert status not in (0, 124), f"exit {status}"
        # The gate engages (public URL off loopback) and finds no provider:
        # the self-hosted one failed construction on the issuer check.
        assert "no auth providers are registered" in out, out
        print(inside("grep -rh 'must be https' /tmp/refuse/logs"))

    with subtest("secrets are only in the rendered dex config"):
        assert inside("stat -c %a /run/dex/config.yaml").strip() == "600"
        secrets = {
            "client secret": "client-secret-alice",
            "hash": inside("cat ${secrets}/alice.hash").strip(),
        }
        rendered = inside("cat /run/dex/config.yaml")
        assert "@hyperhermes-dex-" not in rendered, rendered
        unit = inside("systemctl cat dex.service")
        match = re.search(r"/nix/store/[^ ]*-config\.yaml", unit)
        assert match, unit
        stored = inside(f"cat {match.group(0)}")
        print(stored)
        for what, secret in secrets.items():
            assert secret in rendered, what
            assert secret not in stored, what
        for placeholder in ("@hyperhermes-dex-client-secret-hermes-alice@", "@hyperhermes-dex-hash-alice@"):
            assert placeholder in stored, placeholder

    with subtest("sign in at dex, end on an authenticated dashboard API call"):
        print(machine.succeed(
            "${python}/bin/python3 ${./login.py} http://alice.${domain}:${toString port} "
            "alice@${domain} alice-password hermes-alice"
        ))

    with subtest("an account outside hermes-alice is refused at alice's dashboard"):
        print(machine.succeed(
            "${python}/bin/python3 ${./login.py} --refused http://alice.${domain}:${toString port} "
            "bob@${domain} bob-password hermes-alice"
        ))

    with subtest("the app's sign-in: fresh login at dex, bearer tokens, refresh; bob refused"):
        print(machine.succeed(
            "${python}/bin/python3 ${./login.py} --native http://alice.${domain}:${toString port} "
            "alice@${domain} alice-password hermes-alice"
        ))
        print(machine.succeed(
            "${python}/bin/python3 ${./login.py} --native --refused http://alice.${domain}:${toString port} "
            "bob@${domain} bob-password hermes-alice"
        ))
  '';
}
