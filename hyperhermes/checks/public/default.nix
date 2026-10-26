# Public mode end to end, with stand-ins for the internet: pebble (the
# ACME test CA nixpkgs' acme tests use) issuing by DNS-01 through lego's
# `exec` provider into pebble-challtestsrv, which is also every node's DNS
# (it answers every name with the server's address), and dex as the
# deployment's identity provider at https://id.<front door>.
#
# The server runs the exposure (public), sso, dashboards and publish
# modules with one agent, alice, and a front door. A client node, with the
# test CA as its only trust, checks:
# - TLS on every published name, from the ACME certificates
#   (hermes-fyi for *.<domain>, hermes-fyi-alice for alice's ports,
#   hermes-subdomains for the front door, hermes-dashboards for the legacy
#   domain), and 80 -> 443,
# - alice signs in to her dashboard (hermes' OIDC login against the
#   issuer), at the front door, which sends her to her dashboard, and on
#   her private published port (its own login, a __Host- cookie),
# - bob, whom the issuer signs in to every client (dex has no per-client
#   groups), is refused at alice's dashboard, gets the front door's 403
#   and the 403 of alice's private port; her public port needs no login,
# - the legacy names answer 301 (dashboards and ports); the slot's name
#   on a port host's connection answers 421,
# - dnsRecords lists what the zone must hold.
{
  pkgs,
  self,
  hermesPackage,
}:
let
  inherit (pkgs) lib;
  domain = "agents.test";
  frontDoor = "hermes.example.test";
  legacyDomain = "old.example.test";
  issuer = "https://id.${frontDoor}";
  secrets = "/var/lib/public-secrets";
  # alice is uid 1001: published ports 30010-30014 private, 30015- public.
  alicePrivate = 30010;
  alicePublic = 30015;
  portHost = p: "${toString p}.alice.${domain}";
  echoService = p: {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "alice";
      ExecStart = "${pkgs.python3}/bin/python3 ${../publish/echo.py} ${toString p} /run/echo-${toString p}/log";
      RuntimeDirectory = "echo-${toString p}";
    };
  };
  pebbleRoot = "/run/pebble-root.pem";
  caa = ''0 issue "pebble.test; validationmethods=dns-01"'';
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.requests
  ]);
  certs = [
    "hermes-fyi"
    "hermes-fyi-alice"
    "hermes-subdomains"
    "hermes-dashboards"
  ];
  # The client trusts pebble's root alone.
  withRoot = "env SSL_CERT_FILE=${pebbleRoot} REQUESTS_CA_BUNDLE=${pebbleRoot}";
in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  let
    serverIP = nodes.server.networking.primaryIPAddress;
    dnsIP = nodes.dnsserver.networking.primaryIPAddress;
    dnsHook = pkgs.writeShellScript "dns-hook" ''
      set -euo pipefail
      if [ "$1" = "present" ]; then
        ${pkgs.curl}/bin/curl -sf --data "{\"host\": \"$2\", \"value\": \"$3\"}" http://${dnsIP}:8055/set-txt
      else
        ${pkgs.curl}/bin/curl -sf --data "{\"host\": \"$2\"}" http://${dnsIP}:8055/clear-txt
      fi
    '';
  in
  {
    name = "hyperhermes-public";

    nodes = {
      dnsserver = {
        networking.firewall.allowedTCPPorts = [
          8055
          53
        ];
        networking.firewall.allowedUDPPorts = [ 53 ];
        systemd.services.pebble-challtestsrv = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.pebble}/bin/pebble-challtestsrv -dns01 ':53' -defaultIPv6 '' -defaultIPv4 '${serverIP}'";
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
          };
        };
      };

      acme = {
        imports = [ "${pkgs.path}/nixos/tests/common/acme/server" ];
        networking.nameservers = lib.mkForce [ dnsIP ];
      };

      server =
        { config, ... }:
        {
          imports = [ self.nixosModules.default ];
          virtualisation.memorySize = 4096;
          virtualisation.diskSize = 8192;
          networking.nameservers = lib.mkForce [ dnsIP ];
          # lego talks to pebble's API under the test CA's own certificate.
          security.pki.certificateFiles = [ nodes.acme.test-support.acme.caCert ];
          security.acme.defaults.server = "https://${nodes.acme.test-support.acme.caDomain}/dir";
          # challtestsrv answers at once; nothing to wait for.
          security.acme.certs = lib.genAttrs certs (_: {
            dnsPropagationCheck = false;
          });
          environment.systemPackages = [ pkgs.openssl ];

          services.hyperhermes = {
            package = hermesPackage;
            pythonPackages = _: [ ];
            agents.alice.uid = 1001;
            exposure = {
              enable = true;
              mode = "public";
              inherit domain;
              publicIPv4 = serverIP;
              publicIPv6 = "2001:db8::1";
              acme = {
                dnsProvider = "exec";
                # lego reads <VAR>_FILE for any of its variables.
                credentialFiles.EXEC_PATH_FILE = "${secrets}/exec-path";
                email = "hostmaster@example.test";
                dnsResolver = "${dnsIP}:53";
                inherit caa;
              };
            };
            sso = {
              enable = true;
              inherit issuer;
              accounts.alice = "alice";
              frontDoor = {
                host = frontDoor;
                cookieSecretFile = "${secrets}/cookie.secret";
              };
              clients = lib.mapAttrs (id: _: {
                secretFile = "${secrets}/${id}.secret";
              }) config.services.hyperhermes.sso.oidcClients;
            };
            dashboards = {
              enable = true;
              inherit legacyDomain;
            };
            publish = {
              enable = true;
              cookieSecretFile = "${secrets}/serve-cookie";
              legacyFrontDoorPorts = true;
            };
          };

          # alice's apps on one private and one public port.
          systemd.services."echo-${toString alicePrivate}" = echoService alicePrivate;
          systemd.services."echo-${toString alicePublic}" = echoService alicePublic;

          # The deployment's identity provider: dex, with exactly the
          # clients sso.oidcClients lists, behind this nginx under the front
          # door's certificate.
          services.dex = {
            enable = true;
            settings = {
              inherit issuer;
              storage.type = "memory";
              web.http = "127.0.0.1:5556";
              enablePasswordDB = true;
              oauth2.skipApprovalScreen = true;
              staticClients = lib.mapAttrsToList (id: c: {
                inherit id;
                inherit (c) name;
                redirectURIs = c.callbackURLs;
                secretFile = "${secrets}/${id}.secret";
              }) config.services.hyperhermes.sso.oidcClients;
              staticPasswords = [
                {
                  email = "alice@example.test";
                  username = "alice";
                  preferredUsername = "alice";
                  userID = "alice";
                  hash = "@ALICE_HASH@";
                  groups = [
                    "hermes-alice"
                    "hermes"
                  ];
                }
                {
                  email = "bob@example.test";
                  username = "bob";
                  preferredUsername = "bob";
                  userID = "bob";
                  hash = "@BOB_HASH@";
                  groups = [ "hermes" ];
                }
              ];
            };
          };
          systemd.services.dex.serviceConfig.ExecStartPre = lib.mkAfter [
            "+${pkgs.writeShellScript "dex-hashes" ''
              ${pkgs.replace-secret}/bin/replace-secret @ALICE_HASH@ ${secrets}/alice.hash /run/dex/config.yaml
              ${pkgs.replace-secret}/bin/replace-secret @BOB_HASH@ ${secrets}/bob.hash /run/dex/config.yaml
            ''}"
          ];
          services.nginx.virtualHosts."id.${frontDoor}" = {
            forceSSL = true;
            useACMEHost = "hermes-subdomains";
            locations."/".proxyPass = "http://127.0.0.1:5556";
          };

          # The issuer's certificate chains to pebble's root, which exists
          # only at runtime: hermes and oauth2-proxy trust it alone.
          systemd.services.hermes-dashboard-alice.environment.SSL_CERT_FILE = pebbleRoot;
          systemd.services.oauth2-proxy.environment.SSL_CERT_FILE = pebbleRoot;
          systemd.services.oauth2-proxy-serve.environment.SSL_CERT_FILE = pebbleRoot;

          # Stand-ins for the deployment's secrets, created at runtime.
          systemd.services.public-secrets = {
            wantedBy = [ "multi-user.target" ];
            requiredBy = [
              "dex.service"
              "hermes-agent-alice.service"
              "oauth2-proxy.service"
              "oauth2-proxy-serve.service"
            ]
            ++ map (cert: "acme-order-renew-${cert}.service") certs;
            before = config.systemd.services.public-secrets.requiredBy;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path = [ pkgs.openssl ];
            script = ''
              install -d -m 755 ${secrets}
              echo -n ${dnsHook} > ${secrets}/exec-path
              for id in ${toString (lib.attrNames config.services.hyperhermes.sso.oidcClients)}; do
                echo -n "secret-$id" > ${secrets}/$id.secret
              done
              # oauth2-proxy decodes URL-safe base64 only.
              openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n' > ${secrets}/cookie.secret
              openssl rand -hex 16 | tr -d '\n' > ${secrets}/serve-cookie
              for user in alice bob; do
                ${python}/bin/python3 -c "import bcrypt, sys; sys.stdout.write(bcrypt.hashpw(b'$user-password', bcrypt.gensalt(10)).decode())" \
                  > ${secrets}/$user.hash
              done
            '';
          };
        };

      client = {
        networking.nameservers = lib.mkForce [ dnsIP ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.openssl
        ];
      };
    };

    testScript = ''
      import json

      dns_records = json.loads(${builtins.toJSON (builtins.toJSON nodes.server.services.hyperhermes.exposure.dnsRecords)})

      dnsserver.start()
      acme.start()
      dnsserver.wait_for_open_port(53)
      acme.wait_for_unit("pebble.service")
      acme.wait_for_open_port(443)
      server.start()
      client.start()

      with subtest("ACME issues every certificate by DNS-01"):
          for cert in ("hermes-fyi", "hermes-fyi-alice", "hermes-subdomains", "hermes-dashboards"):
              server.wait_until_succeeds(
                  f"openssl x509 -in /var/lib/acme/{cert}/cert.pem -noout -issuer | grep -i pebble",
                  timeout=300,
              )
          print(server.succeed("openssl x509 -in /var/lib/acme/hermes-fyi/cert.pem -noout -ext subjectAltName"))
          server.succeed("openssl x509 -in /var/lib/acme/hermes-subdomains/cert.pem -noout -ext subjectAltName | grep -F 'DNS:${frontDoor}'")
          server.succeed("openssl x509 -in /var/lib/acme/hermes-fyi-alice/cert.pem -noout -ext subjectAltName | grep -F 'DNS:*.alice.${domain}'")

      root = acme.succeed(
          "curl -sf --cacert ${nodes.acme.test-support.acme.caCert} https://${nodes.acme.test-support.acme.caDomain}:15000/roots/0"
      )
      for node in (server, client):
          node.succeed(f"cat > ${pebbleRoot} <<'EOF'\n{root}\nEOF")
      server.wait_until_succeeds("systemctl reload nginx && sleep 1 && curl -sf --cacert ${pebbleRoot} ${issuer}/.well-known/openid-configuration")
      server.wait_for_unit("hermes-dashboard-alice.service")

      with subtest("TLS from the ACME certificates, 80 redirects"):
          client.wait_until_succeeds("curl -sf --cacert ${pebbleRoot} https://alice.${domain}/api/status", timeout=120)
          client.succeed("curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code}' https://nothing.${domain}/ | grep -x 404")
          client.succeed("curl -s -o /dev/null -w '%{redirect_url}' http://alice.${domain}/x | grep -x https://alice.${domain}/x")

      with subtest("alice signs in to her dashboard"):
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${../local-sso/login.py} https://alice.${domain} "
              "alice@example.test alice-password hermes-alice,hermes"
          ))

      with subtest("bob, signed in by the issuer, is refused at alice's dashboard"):
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${../local-sso/login.py} --refused https://alice.${domain} "
              "bob@example.test bob-password hermes-alice"
          ))

      with subtest("front door"):
          client.wait_until_succeeds("curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code}' https://${frontDoor}/ | grep -E '^30[27]$'", timeout=120)
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${./front.py} https://${frontDoor} alice@example.test alice-password https://alice.${domain}"
          ))
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${./front.py} https://${frontDoor} bob@example.test bob-password -"
          ))

      with subtest("the legacy name redirects"):
          client.succeed(
              "curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code} %{redirect_url}' https://alice.${legacyDomain}/a?b "
              "| grep -x '301 https://alice.${domain}/a?b'"
          )

      with subtest("published ports: alice's private one after her login, bob refused, the public one open"):
          client.wait_until_succeeds("curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code}' https://${portHost alicePrivate}/ | grep -x 302", timeout=120)
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${../publish/serve.py} https://${portHost alicePrivate}/p "
              "alice@example.test alice-password ok"
          ))
          print(client.succeed(
              "${withRoot} ${python}/bin/python3 ${../publish/serve.py} https://${portHost alicePrivate}/ "
              "bob@example.test bob-password forbidden"
          ))
          client.succeed("curl -sf --cacert ${pebbleRoot} https://${portHost alicePublic}/ | grep -x 'backend ${toString alicePublic}'")
          # The port's old name below the front door, and the slot's name
          # on a port host's connection.
          client.succeed(
              "curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code} %{redirect_url}' https://${toString alicePublic}.${frontDoor}/a?b "
              "| grep -x '301 https://${portHost alicePublic}/a?b'"
          )
          client.succeed("curl -s --cacert ${pebbleRoot} -o /dev/null -w '%{http_code}' https://slot.alice.${domain}/ | grep -x 421")

      with subtest("dnsRecords"):
          print(dns_records)
          have = {(r["name"], r["type"]) for r in dns_records}
          for want in [
              ("*.${domain}", "A"), ("*.${domain}", "AAAA"), ("alice.${domain}", "A"),
              ("alice.${domain}", "TXT"), ("${frontDoor}", "CAA"), ("*.${legacyDomain}", "A"),
              ("${legacyDomain}", "CAA"), ("_dmarc.${domain}", "TXT"),
              ("*.alice.${domain}", "A"), ("*.alice.${domain}", "AAAA"),
          ]:
              assert want in have, want
          assert ("*.${domain}", "TXT") not in have
          assert ("*.alice.${domain}", "TXT") not in have
    '';
  }
)
