# ./default.nix with som's names (../../../machines/som/atproto-pds.nix) in
# a NixOS container, nginx on plain http (no certificate here). Covered:
# atproto-pds-accounts creates dave.davhau.com as did:web:dave.davhau.com
# with the bootstrap invite code; dave.davhau.com/.well-known/did.json and
# /atproto-did through nginx (Host kept) and resolveHandle; createSession
# with the password var; a rerun is a no-op (hash untouched); a changed var
# replaces the password (old one refused) and revokes what the old one made
# (session access and refresh tokens, app passwords); /metrics is not
# served through nginx; a restart of the PDS reruns the
# unit without a bootstrap code; signup without an invite code is refused;
# the handle host serves nothing else; a non-root, non-nginx uid cannot
# dial the PDS port.
{ pkgs }:
let
  inherit (pkgs) lib;
  clanStub = {
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
                      default = "/run/test-vars/${generator}/${name}";
                    };
                  }
                )
              );
            };
          }
        )
      );
    };
    # clan's backup and postgres modules: not under test here.
    options.clan.core.postgresql = lib.mkOption { type = lib.types.anything; };
    options.clan.core.state = lib.mkOption { type = lib.types.anything; };
  };
  secretsEnv = pkgs.writeText "atproto-pds-secrets-env" ''
    JWT_SECRET=test-jwt-secret-0123456789abcdef0123456789abcdef
    DPOP_SECRET=test-dpop-secret-0123456789abcdef0123456789abcdef
    MASTER_KEY=test-master-key-0123456789abcdef0123456789abcdef
    RIPPLE_CLUSTER_KEY=test-ripple-key-0123456789abcdef0123456789abcdef
  '';
in
pkgs.testers.runNixOSTest {
  name = "atproto-pds";
  globalTimeout = 900;

  containers.som = {
    imports = [
      ./.
      clanStub
    ];
    hyper.atprotoPds = {
      enable = true;
      hostname = "pds.davhau.com";
      handleDomain = "davhau.com";
      tls = { };
      accounts.dave = {
        handle = "dave.davhau.com";
        email = "info@davhau.com";
      };
    };
    systemd.tmpfiles.rules = [
      "d /run/test-vars/atproto-pds-secrets 0700 root root -"
      "L+ /run/test-vars/atproto-pds-secrets/env - - - - ${secretsEnv}"
      "d /run/test-vars/atproto-pds-dave-password 0700 root root -"
      "f /run/test-vars/atproto-pds-dave-password/password 0400 root root - Pds1-initialPassw0rd"
    ];
    users.users.mallory = {
      isNormalUser = true;
      uid = 1500;
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];
  };

  testScript = ''
    import json

    def xrpc(method, body=None, host="pds.davhau.com", code=200, token=None):
        cmd = f"curl -s -o /tmp/out -w '%{{http_code}}' -H 'Host: {host}' "
        if token is not None:
            cmd += f"-H 'Authorization: Bearer {token}' "
        if body is not None:
            cmd += f"-H 'Content-Type: application/json' --data '{json.dumps(body)}' "
        cmd += f"http://127.0.0.1/xrpc/{method}"
        status = som.succeed(cmd).strip()
        out = som.succeed("cat /tmp/out")
        assert status == str(code), f"{method}: {status} {out}"
        return json.loads(out) if out.strip() else {}

    def login(password, code=200):
        return xrpc("com.atproto.server.createSession",
                    {"identifier": "dave.davhau.com", "password": password}, code=code)

    def pw_hash():
        return som.succeed(
            "runuser -u tranquil-pds -- psql -d tranquil-pds -tAc "
            "\"SELECT password_hash FROM users WHERE did = 'did:web:dave.davhau.com'\"").strip()

    start_all()

    with subtest("the oneshot creates the account with the bootstrap invite code"):
        som.wait_for_unit("atproto-pds-accounts.service", timeout=300)
        som.succeed("journalctl -u atproto-pds-accounts -o cat | grep -F 'dave: created did:web:dave.davhau.com'")
        som.wait_for_unit("nginx.service")

    with subtest("did:web document on the handle host, through nginx"):
        doc = json.loads(som.succeed(
            "curl -sf -H 'Host: dave.davhau.com' http://127.0.0.1/.well-known/did.json"))
        print(doc)
        assert doc["id"] == "did:web:dave.davhau.com", doc
        svc = [s for s in doc["service"] if s["id"] == "#atproto_pds"]
        assert svc and svc[0]["serviceEndpoint"] == "https://pds.davhau.com", doc
        assert "at://dave.davhau.com" in doc.get("alsoKnownAs", []), doc
        did = som.succeed(
            "curl -sf -H 'Host: dave.davhau.com' http://127.0.0.1/.well-known/atproto-did").strip()
        assert did == "did:web:dave.davhau.com", did
        # nothing else of the PDS on the handle host
        som.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: dave.davhau.com' "
            "http://127.0.0.1/xrpc/_health) = 404")

    with subtest("resolveHandle"):
        r = xrpc("com.atproto.identity.resolveHandle?handle=dave.davhau.com")
        assert r["did"] == "did:web:dave.davhau.com", r

    with subtest("login with the var's password"):
        s = login("Pds1-initialPassw0rd")
        assert s["did"] == "did:web:dave.davhau.com" and s["handle"] == "dave.davhau.com", s

    with subtest("rerun is a no-op"):
        before = pw_hash()
        som.succeed("systemctl restart atproto-pds-accounts.service")
        som.succeed("journalctl -u atproto-pds-accounts -o cat | grep -F 'dave: did:web:dave.davhau.com unchanged'")
        assert pw_hash() == before
        login("Pds1-initialPassw0rd")

    with subtest("/metrics is not served through nginx"):
        som.succeed("curl -sf http://127.0.0.1:2583/metrics >/dev/null")
        som.succeed(
            "test $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: pds.davhau.com' "
            "http://127.0.0.1/metrics) = 404")

    with subtest("a changed var replaces the password and revokes the old one's sessions"):
        old = login("Pds1-initialPassw0rd")
        assert xrpc("com.atproto.server.getSession", token=old["accessJwt"])["did"] == "did:web:dave.davhau.com"
        app = xrpc("com.atproto.server.createAppPassword", {"name": "leaky"}, token=old["accessJwt"])
        login(app["password"])
        som.succeed("printf 'Dave2-NewSecretPassw0rd' > /run/test-vars/atproto-pds-dave-password/password")
        som.succeed("systemctl restart atproto-pds-accounts.service")
        som.succeed("journalctl -u atproto-pds-accounts -o cat | grep -F 'dave: password applied to did:web:dave.davhau.com'")
        # the unit restarts the PDS, which reruns the unit: wait for that
        som.wait_until_succeeds(
            "test $(journalctl -u atproto-pds-accounts -o cat | grep -cF 'dave: did:web:dave.davhau.com unchanged') -ge 2",
            timeout=120)
        som.wait_for_unit("atproto-pds-accounts.service")
        login("Dave2-NewSecretPassw0rd")
        login("Pds1-initialPassw0rd", code=401)
        login(app["password"], code=401)
        for method, tok in (("com.atproto.server.getSession", old["accessJwt"]),
                            ("com.atproto.server.refreshSession", old["refreshJwt"])):
            cmd = (f"curl -s -o /tmp/out -w '%{{http_code}}' -H 'Host: pds.davhau.com' "
                   f"-H 'Authorization: Bearer {tok}' "
                   + ("-X POST " if method.endswith("refreshSession") else "")
                   + f"http://127.0.0.1/xrpc/{method}")
            status = som.succeed(cmd).strip()
            assert status in ("400", "401"), f"{method} with the old session: {status} {som.succeed('cat /tmp/out')}"

    with subtest("a restart of the PDS reruns the unit, no bootstrap code"):
        som.succeed("systemctl restart tranquil-pds.service")
        som.wait_until_succeeds(
            "test $(journalctl -u atproto-pds-accounts -o cat | grep -cF 'dave: did:web:dave.davhau.com unchanged') -ge 3",
            timeout=120)
        som.fail(
            "journalctl -o cat _SYSTEMD_INVOCATION_ID=$(systemctl show -P InvocationID tranquil-pds.service)"
            " | grep -F 'Bootstrap invite code'")
        login("Dave2-NewSecretPassw0rd")

    with subtest("no signup without an invite code"):
        r = xrpc("com.atproto.server.createAccount",
                 {"handle": "eve.davhau.com", "email": "eve@example.com",
                  "password": "Eve1-Passw0rdLong", "didType": "web"}, code=400)
        assert r.get("error") in ("InviteCodeRequired", "InvalidInviteCode"), r

    with subtest("only root and nginx dial the PDS port"):
        som.succeed("curl -sf http://127.0.0.1:2583/xrpc/_health")
        som.fail("runuser -u mallory -- curl -sf --max-time 5 http://127.0.0.1:2583/xrpc/_health")
  '';
}
