# ./agent-tools.nix and ./agent-tools-guest.nix on one host (som): the
# infra-space container with its hermes, som's mail (Stalwart, mailgate,
# a second mailbox for the host agent alice), the shared wallet and the
# infra-browser Camofox server, Mullvad egress unregistered (no tunnel,
# so the browser has no internet; its loopback and veth refusals are
# what is tested). The node runs with the browser off (the default), its
# specialisation `browser` with hyper.infraSpace.agentTools.browser on.
# Covered, in the guest as infra:
#   - mail: `mailgate status` answers as infra@<domain>, its quarantine
#     holds infra's mail and not alice's, himalaya logs into the IMAP
#     proxy;
#   - wallet: `lnwallet getinfo` through the proxy, against a stand-in for
#     phoenixd's API (phoenixd itself never opens its API offline,
#     hyperhermes checks/wallet says why) that checks the password;
#   - mail: whole-domain allowlist entries refused for infra's mailbox
#     (its request, mailgate-admin), accepted for alice's;
#   - browser off: hermes' own resolution (./agent-tools-toolsets.py, the
#     installed hermes as infra in the gateway's environment) has no
#     camofox toolset on cli, telegram, cron, acp, api_server, no camofox
#     plugin, no CAMOFOX_* variable; on the host no 9144 listener, no
#     infra-browser user, key unit, credential or nft chain;
#   - browser on (specialisation): camofox on every one of those
#     platforms; the server's /health and a new tab (Camoufox starts)
#     through the bridge with the access key, refused without it; the
#     server's replies pass the browser's output chain.
# Refused: another guest uid on every tool port and the guest's mailgate
# socket; a host user (`tenant`) on every tool port; the browser's uid to
# a loopback service and to the veth address, while it still reaches its
# own backend.
{
  pkgs,
  inputs,
}:
let
  inherit (pkgs) lib;
  hlib = inputs.hyperhermes.lib;
  keys = ./test-keys;
  pub = file: lib.trim (builtins.readFile (keys + "/${file}"));
  domain = "agents.test";
  walletPassword = "test-wallet-password";
  vethHost = "10.235.0.1";
  ports = {
    mail = 9141;
    imap = 9142;
    wallet = 9143;
    browser = 9144;
  };
  browserUid = 1217;
  backend = hlib.camofoxBackendBase + browserUid;
  probePort = 8000;

  cert = pkgs.runCommand "mx-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=mail.${domain} \
      -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
  '';

  # LMTP straight to mailgate, as Stalwart would deliver (root may dial it).
  lmtpSend = pkgs.writeText "lmtp-send.py" ''
    import base64, socket, sys
    rcpt, subject = sys.argv[1], sys.argv[2]
    secret = open("/etc/test-vars/mail/lmtp").read().strip()
    s = socket.create_connection(("127.0.0.1", 24), 30)
    f = s.makefile("rwb")
    def cmd(line):
        if line is not None:
            f.write(line.encode() + b"\r\n"); f.flush()
        while True:
            r = f.readline().decode()
            if r[3:4] != "-":
                return r.strip()
    cmd(None)
    cmd("LHLO client")
    assert cmd("AUTH PLAIN " + base64.b64encode(b"\0stalwart\0" + secret.encode()).decode()).startswith("235")
    assert cmd("MAIL FROM:<someone@elsewhere.test>").startswith("250")
    assert cmd(f"RCPT TO:<{rcpt}>").startswith("250")
    assert cmd("DATA").startswith("354")
    f.write(f"From: someone@elsewhere.test\r\nTo: {rcpt}\r\nSubject: {subject}\r\n\r\nhello\r\n.\r\n".encode()); f.flush()
    r = cmd(None)
    assert r.startswith("250"), r
    cmd("QUIT")
    print("OK")
  '';

  # phoenixd's API as phoenix-cli sees it (hyperhermes checks/wallet).
  fakeApi = pkgs.writers.writePython3 "fake-phoenixd-api" { } ''
    import base64
    from http.server import BaseHTTPRequestHandler, HTTPServer


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            pw = ""
            if auth.startswith("Basic "):
                pw = base64.b64decode(auth[6:]).decode().partition(":")[2]
            if pw == "${walletPassword}":
                body = b'{"nodeId": "fake-node"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="phoenix"')
                self.send_header("Content-Length", "0")
                self.end_headers()


    HTTPServer(("127.0.0.1", 9740), Handler).serve_forever()
  '';

  secret = text: {
    inherit text;
    mode = "0400";
  };
in
pkgs.testers.runNixOSTest {
  name = "infra-space-agent-tools";
  globalTimeout = 1800;
  node.specialArgs = { inherit inputs; };

  nodes.som =
    { config, ... }:
    {
      imports = [
        ./test-clan-stub.nix
        ./default.nix
        ./agent-tools.nix
        ../mullvad-egress/egress.nix
        ../mullvad-egress/dns.nix
        inputs.hyperhermes.nixosModules.core
        inputs.hyperhermes.nixosModules.exposure
        inputs.hyperhermes.nixosModules.mail
        inputs.hyperhermes.nixosModules.browser
        inputs.hyperhermes.nixosModules.wallet
        # what clan provides for vit's yggdrasil address (./agent-tools.nix):
        # the repo's vars, only that one
        {
          options.clan.core.settings.directory = lib.mkOption {
            default = lib.fileset.toSource {
              root = ../../..;
              fileset = ../../../vars/per-machine/vit/yggdrasil/address;
            };
          };
        }
      ];
      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.tpm.enable = true;
      networking.nftables.enable = true;
      networking.useNetworkd = true;
      services.resolved.enable = true;
      boot.kernel.sysctl."kernel.io_uring_disabled" = 2;
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
      ];
      users.users.tenant.isNormalUser = true;
      # the host agent's pip venv without the data-science set
      services.hyperhermes.pythonPackages = _: [ ];

      hyper.infraSpace = {
        enable = true;
        hermes = true;
        member = "som";
        meshInterface = "eth1";
        members.som = {
          address = config.networking.primaryIPv6Address;
          sshPort = 2223;
          hostKey = pub "hostkey-memberA.pub";
        };
        sshPublicKey = pub "infra-space.pub";
        fleetCertAuthority = {
          publicKey = pub "ca.pub";
          hostNames = [ "managed" ];
        };
        gcRoots = {
          machines = [ "testbox" ];
          closureMachines = [ ];
        };
      };
      clan.core.vars.generators = {
        inference-api-key.files.token = { };
        teamclaude-api-key.files.key = { };
        openrouter.files.apikey = { };
      };

      # A host agent with its own mailbox (none of its units run).
      services.hyperhermes.agents.alice = {
        uid = 1001;
        browser.enable = false;
        mail.passwordFile = "/etc/test-vars/mail/imap-alice";
      };
      systemd.services.hermes-agent-alice.enable = false;
      systemd.services.hermes-dashboard-alice.enable = false;
      systemd.services.hermes-python-venv-alice.enable = false;

      services.hyperhermes = {
        exposure = {
          enable = true;
          mode = "public";
          domain = "site.test";
          acme = {
            dnsProvider = "porkbun";
            credentialFiles = {
              PORKBUN_API_KEY_FILE = "/etc/test-vars/mail/porkbun";
              PORKBUN_SECRET_API_KEY_FILE = "/etc/test-vars/mail/porkbun";
            };
          };
        };
        mail = {
          enable = true;
          inherit domain;
          secrets = lib.genAttrs [ "master" "hook" "lmtp" "csrf" ] (n: "/etc/test-vars/mail/${n}");
          acme = false;
          tls = {
            certFile = "${cert}/cert.pem";
            keyFile = "${cert}/key.pem";
          };
          remoteMailboxes.infra.passwordFile = "/etc/test-vars/mail/imap-infra";
        };
        browser.enable = true;
        wallet = {
          enable = true;
          seedFile = "/run/wallet-test/seed";
          apiConfigFile = "/run/wallet-test/api/phoenix.conf";
        };
      };
      security.acme.defaults.server = "https://127.0.0.1:1/directory";

      # Unregistered: no tunnel, the tunneled users get no internet.
      hyper.mullvadEgress = {
        privateKeyFile = "/dev/null";
        relays = [
          {
            endpoint = "192.0.2.1:51820";
            publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          }
        ];
      };

      specialisation.browser.configuration.hyper.infraSpace.agentTools.browser = true;

      # hermes' own view of infra's toolsets (./agent-tools-toolsets.py).
      hyper.infraSpace.guestModules = [
        (
          { config, pkgs, ... }:
          {
            environment.systemPackages = [
              (pkgs.writeShellScriptBin "infra-agent-toolsets" ''
                exec ${config.services.hyperhermes.package.hermesVenv}/bin/python3 ${./agent-tools-toolsets.py}
              '')
            ];
          }
        )
      ];

      # A loopback service the browser must not reach.
      systemd.services.loopback-probe = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = true;
          ExecStart = "${pkgs.python3}/bin/python3 -m http.server ${toString probePort} --bind 127.0.0.1 --directory /etc";
        };
      };

      systemd.tmpfiles.rules = [
        "d /run/wallet-test 0755 root root - -"
        "d /run/wallet-test/api 0755 root root - -"
        "f /run/wallet-test/seed 0400 phoenixd phoenixd - abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        "f /run/wallet-test/api/phoenix.conf 0440 phoenixd lightning-wallet - http-password=${walletPassword}"
      ];

      environment.etc = {
        "test-vars/infra-space-ssh/id_ed25519" = {
          source = keys + "/infra-space";
          mode = "0400";
        };
        "test-vars/infra-space-brief/id_ed25519" = {
          source = keys + "/brief";
          mode = "0400";
        };
        "test-vars/infra-space-hostkey/ssh_host_ed25519_key" = {
          source = keys + "/hostkey-memberA";
          mode = "0400";
        };
        "test-vars/infra-space-github/id_ed25519" = secret "not a key\n";
        "test-vars/infra-space-secrets-github/id_ed25519" = secret "not a key\n";
        "test-vars/inference-api-key/token" = secret "test-p0-token\n";
        "test-vars/teamclaude-api-key/key" = secret "test-teamclaude\n";
        "test-vars/openrouter/apikey" = secret "test-openrouter\n";
        "test-vars/mail/master" = secret "test-master-secret";
        "test-vars/mail/hook" = secret "test-hook-secret";
        "test-vars/mail/lmtp" = secret "test-lmtp-secret";
        "test-vars/mail/csrf" = secret "test-csrf-key";
        "test-vars/mail/imap-infra" = secret "infra-imap-password";
        "test-vars/mail/imap-alice" = secret "alice-imap-password";
        "test-vars/mail/porkbun" = secret "unused";
      };
    };

  testScript =
    { nodes, ... }:
    let
      guestCfg = nodes.som.containers.infra-space.config;
      # the agent's own tools, as on its unit's PATH (extraPackages)
      tool =
        name:
        "${
          lib.findFirst (
            p: (p.name or "") == name || lib.getName p == name
          ) (throw "infra has no ${name}") guestCfg.services.hyperhermes.agents.infra.extraPackages
        }/bin/${name}";
      curl = "${pkgs.curl}/bin/curl";
      bash = "${pkgs.bash}/bin/bash";
      toolPorts = with ports; [
        mail
        imap
        wallet
      ];
    in
    ''
      import json
      import shlex

      def guest(cmd):
          return som.succeed("nixos-container run infra-space -- runuser -u infra -- bash -lc " + shlex.quote(cmd))

      def guest_as_nobody(cmd):
          return som.execute(
              "nixos-container run infra-space -- setpriv --reuid=65534 --regid=65534 --clear-groups "
              + "${bash} -c " + shlex.quote(cmd)
          )

      def dial(port):
          return "exec 3<>/dev/tcp/${vethHost}/" + str(port)

      def wait_guest():
          som.wait_for_unit("container@infra-space.service")
          som.wait_until_succeeds(
              "nixos-container run infra-space -- systemctl is-active infra-space-secrets.service "
              "infra-agent-tools-firewall.service infra-mailgate.socket hermes-agent-infra.service",
              timeout=180,
          )

      def hermes_view():
          # the installed hermes as infra, in the gateway's own environment
          # (HERMES_HOME, bundled plugins, CAMOFOX_*), as ./test.nix does
          check = (
              "pid=$(systemctl show -p MainPID --value hermes-agent-infra.service); "
              "mapfile -d ''' < /proc/$pid/environ envs; "
              'exec runuser -u infra -- env -i "''${envs[@]}" /run/current-system/sw/bin/infra-agent-toolsets'
          )
          out = som.succeed("nixos-container run infra-space -- bash -c " + shlex.quote(check))
          got = json.loads(out.strip().splitlines()[-1])
          print(json.dumps(got))
          assert got["hermes_home"], got
          assert sorted(got["platforms"]) == ["acp", "api_server", "cli", "cron", "telegram"], got
          return got

      start_all()
      wait_guest()
      # the guest's gate came up at boot, not only on a retry
      shown = som.succeed(
          "nixos-container run infra-space -- systemctl show -p NRestarts -p Result infra-agent-tools-firewall.service"
      ).split()
      assert sorted(shown) == ["NRestarts=0", "Result=success"], shown
      for unit in ["mailgate.service", "stalwart.service", "mailgate-imap-passwords.service", "phoenixd.service"]:
          som.wait_for_unit(unit)
      som.wait_for_open_port(143, "127.0.0.1")

      with subtest("browser off: no camofox in hermes, nothing of it on the host"):
          got = hermes_view()
          for platform, sets in got["platforms"].items():
              assert "terminal" in sets, (platform, sets)
              assert "camofox" not in sets, (platform, sets)
          assert not [t for t in got["tools"] if t.startswith("browser")], got["tools"]
          assert "camofox" not in got["plugins"], got["plugins"]
          assert got["camofox_env"] == [], got["camofox_env"]
          som.fail("ss -Htln | grep -q ':${toString ports.browser} '")
          som.fail("systemctl cat hermes-camofox-key-infra-browser.service")
          som.fail("systemctl cat hermes-camofox-infra-browser.service")
          som.fail("id infra-browser")
          som.fail("nixos-container run infra-space -- test -e /run/infra-space/secrets/camofox-key")
          som.fail("nft list chain inet infra-space-agent-tools browser")

      with subtest("mail: infra's mailbox through the proxies, and only infra's"):
          som.succeed("python3 ${lmtpSend} infra@${domain} for-infra")
          som.succeed("python3 ${lmtpSend} alice@${domain} for-alice")
          status = json.loads(guest("${tool "mailgate"} status"))
          assert status["address"] == "infra@${domain}", status
          assert status["quarantined"] == 1, status
          q = json.loads(guest("${tool "mailgate"} quarantine --limit 100"))
          assert [m["to"] for m in q] == ["infra@${domain}"], q
          # IMAP through the proxy, with infra's own password
          guest("${tool "himalaya"} envelope list")

      with subtest("mail: no whole-domain allowlist entries for infra's mailbox"):
          for entry in ["@elsewhere.test", "*@elsewhere.test"]:
              out = guest("! ${tool "mailgate"} allowlist request " + shlex.quote(entry) + " --reason signup")
              assert "single addresses only" in out, out
              out = som.succeed("! mailgate-admin allow infra " + shlex.quote(entry))
              assert "single addresses only" in out, out
          out = json.loads(guest("${tool "mailgate"} allowlist request someone@elsewhere.test --reason signup"))
          assert "error" not in out, out
          som.succeed("mailgate-admin allow infra someone@elsewhere.test")
          listed = json.loads(som.succeed("mailgate-admin list infra"))["allowlist"]
          assert [e["entry"] for e in listed] == ["someone@elsewhere.test"], listed
          # other mailboxes keep whole-domain entries
          som.succeed("mailgate-admin allow alice @elsewhere.test")

      with subtest("wallet: lnwallet through the proxy"):
          som.succeed("systemctl stop phoenixd.service")
          som.succeed("systemd-run --unit fake-phoenixd-api ${fakeApi}")
          som.wait_for_open_port(9740)
          out = guest("${tool "lnwallet"} getinfo")
          assert "fake-node" in out, out

      with subtest("other uids reach none of the tool ports"):
          for port in [${lib.concatMapStringsSep ", " toString toolPorts}]:
              rc, out = guest_as_nobody(dial(port))
              assert rc != 0, (port, out)
              som.fail("runuser -u tenant -- ${bash} -c " + shlex.quote(dial(port)))
          # infra and root still do
          guest(dial(${toString ports.wallet}))
          som.succeed("${bash} -c " + shlex.quote(dial(${toString ports.wallet})))
          rc, out = guest_as_nobody("${tool "mailgate"} status")
          assert rc != 0 and "infra@" not in out, out

      with subtest("browser on (specialisation): camofox on every platform"):
          # exit 4 = some unit failed: here only the ACME order (no server)
          rc, out = som.execute("/run/booted-system/specialisation/browser/bin/switch-to-configuration test 2>&1")
          failed = som.succeed("systemctl list-units --failed --plain --no-legend | awk '{print $1}'").split()
          assert rc in (0, 4) and set(failed) <= {"acme-order-renew-hermes-domain.service"}, (rc, failed, out[-2000:])
          som.wait_until_succeeds(
              "nixos-container run infra-space -- test -e /run/infra-space/secrets/camofox-key", timeout=180
          )
          wait_guest()
          got = hermes_view()
          for platform, sets in got["platforms"].items():
              assert "camofox" in sets, (platform, sets)
          assert "camofox" in got["plugins"], got["plugins"]
          assert got["camofox_env"] == ["CAMOFOX_API_KEY", "CAMOFOX_URL"], got["camofox_env"]

      with subtest("browser: the server through the bridge, with its key only"):
          url = "http://${vethHost}:${toString ports.browser}"
          guest(f"${curl} -sf --max-time 120 {url}/health")
          key = "$(cat /run/infra-space/secrets/camofox-key)"
          body = shlex.quote('{"userId":"infra","sessionKey":"t"}')
          tabs = f"${curl} -s -o /dev/null -w '%{{http_code}}' --max-time 120 -X POST -H 'Content-Type: application/json' -d {body} "
          auth = f"-H \"Authorization: Bearer {key}\" "
          assert guest(tabs + f"{url}/tabs").strip() == "401"
          assert guest(tabs + auth + f"{url}/tabs").strip() == "200"
          listed = json.loads(guest("${curl} -sf " + auth + f"'{url}/tabs?userId=infra'"))
          assert len(listed["tabs"]) == 1, listed
          som.succeed("systemctl is-active hermes-camofox-infra-browser.service")

      with subtest("browser's uid: its backend yes, loopback services and the veth no"):
          som.wait_for_open_port(${toString probePort}, "127.0.0.1")
          as_browser = "setpriv --reuid=${toString browserUid} --regid=${toString browserUid} --clear-groups "
          som.succeed(as_browser + "${curl} -sf --max-time 10 http://127.0.0.1:${toString backend}/health")
          som.fail(as_browser + "${curl} -sf --max-time 10 http://127.0.0.1:${toString probePort}/")
          som.fail(as_browser + "${bash} -c " + shlex.quote(dial(${toString ports.mail})))
          som.succeed("${curl} -sf --max-time 10 http://127.0.0.1:${toString probePort}/")

      with subtest("other uids reach not the browser port either"):
          rc, out = guest_as_nobody(dial(${toString ports.browser}))
          assert rc != 0, out
          som.fail("runuser -u tenant -- ${bash} -c " + shlex.quote(dial(${toString ports.browser})))
          guest(dial(${toString ports.browser}))
    '';
}
