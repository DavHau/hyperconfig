# ./home-assistant.nix in a NixOS container (checks.x86_64-linux.owntracks):
# Home Assistant with the seeded OwnTracks and location_api config entries
# (./seed.py), the test's stand-ins for the clan vars. `client` plays the
# phone (an OwnTracks HTTP-mode report, secretbox-encrypted, X-Limit-U/D
# headers as OwnTracks for Android sends them) and the agents (bearer
# tokens). Covered: the encrypted report lands as device_tracker.dave_pixel;
# a report under a wrong key is ignored; the reader gets position, battery
# and track; a wrong or missing token is 401; a source outside `sources`
# (HA's own loopback) is 403 even with a valid token; the endpoint is
# GET-only; a restart keeps exactly one config entry per domain.
# edi's nginx front (./edi.nix) is covered by edi's own build (nginx -t).
{ pkgs }:
let
  inherit (pkgs) lib;
  key = "0123456789abcdef0123456789abcdef";
  webhookId = "testwebhook0123456789abcdef0123456789abcdef0123456789abcdef01234";
  tokenInfra = "infra-token-0123456789";
  tokenDave = "dave-hermes-token-0123456789";
  sha = s: builtins.hashString "sha256" s;
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
  };
  phone = pkgs.writers.writePython3 "owntracks-phone" { libraries = [ pkgs.python3Packages.pynacl ]; } ''
    import base64
    import json
    import sys
    import time
    import urllib.request

    import nacl.secret
    import nacl.utils

    url, key, lat = sys.argv[1], sys.argv[2], float(sys.argv[3])
    msg = {"_type": "location", "lat": lat, "lon": 100.5, "acc": 25,
           "batt": 64, "tst": int(time.time()), "tid": "dh", "vel": 0}
    box = nacl.secret.SecretBox(key.encode()[:32].ljust(32, b"\0"))
    nonce = nacl.utils.random(nacl.secret.SecretBox.NONCE_SIZE)
    data = base64.b64encode(box.encrypt(json.dumps(msg).encode(), nonce))
    body = json.dumps({"_type": "encrypted", "data": data.decode()}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "X-Limit-U": "dave", "X-Limit-D": "pixel"})
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status, r.read().decode())
  '';
in
pkgs.testers.runNixOSTest {
  name = "owntracks";
  globalTimeout = 900;

  containers.ha =
    { ... }:
    {
      imports = [
        ./home-assistant.nix
        clanStub
      ];
      _module.args.inputs = { };
      networking.firewall.allowedTCPPorts = [ 8123 ];
      hyper.owntracks = {
        readerHashes = {
          infra = sha tokenInfra;
          dave-hermes = sha tokenDave;
        };
        # the client's network (as som's yggdrasil address in production)
        readerSources = [
          "192.168.1.0/24"
          "2001:db8:1::/64"
        ];
      };
      services.home-assistant = {
        enable = true;
        # cm-pi's list has pynacl already (payload encryption)
        extraPackages = ps: [ ps.pynacl ];
        config = lib.mkForce {
          homeassistant = {
            name = "test";
            latitude = 13.7;
            longitude = 100.5;
            elevation = 0;
            unit_system = "metric";
            time_zone = "UTC";
          };
          http = { };
          recorder = { };
          logger.default = "info";
        };
      };
      systemd.tmpfiles.rules = [
        "d /run/test-vars/owntracks-secrets 0700 hass hass -"
        "f+ /run/test-vars/owntracks-secrets/webhook-id 0400 hass hass - ${webhookId}"
        "f+ /run/test-vars/owntracks-secrets/encryption-key 0400 hass hass - ${key}"
      ];
    };

  containers.client = {
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
  };

  testScript = ''
    import json

    webhook = "http://ha:8123/api/webhook/${webhookId}"
    api = "http://ha:8123/api/hyper_location"

    def read(token, query="", host="client"):
        node = client if host == "client" else ha
        base = api if host == "client" else "http://127.0.0.1:8123/api/hyper_location"
        return node.succeed(
            f"curl -sS -o /tmp/body -w '%{{http_code}}' -H 'Authorization: Bearer {token}' "
            f"'{base}{query}'; echo; cat /tmp/body"
        ).split("\n", 1)

    start_all()
    ha.wait_for_unit("home-assistant.service")
    ha.wait_until_succeeds("curl -sf http://127.0.0.1:8123/manifest.json", timeout=300)
    client.wait_until_succeeds("curl -sS -o /dev/null http://ha:8123/manifest.json", timeout=120)

    with subtest("seed: one entry per domain, survives a restart"):
        ha.succeed("journalctl -u home-assistant | grep 'config-entry seed: owntracks created, location_api created' >/dev/null")
        ha.systemctl("restart home-assistant")
        ha.wait_until_succeeds("curl -sf http://127.0.0.1:8123/manifest.json", timeout=300)
        entries = json.loads(ha.succeed("cat /var/lib/hass/.storage/core.config_entries"))["data"]["entries"]
        domains = sorted(e["domain"] for e in entries)
        assert domains.count("owntracks") == 1 and domains.count("location_api") == 1, domains

    with subtest("no position yet: 503"):
        client.wait_until_succeeds(
            f"test \"$(curl -sS -o /dev/null -w '%{{http_code}}' {api})\" != 404", timeout=120
        )
        code, _ = read("${tokenInfra}")
        assert code == "503", code

    with subtest("an encrypted report lands as device_tracker.dave_pixel"):
        # OwnTracks' webhook registers a moment after HA answers: resend
        client.wait_until_succeeds(
            f"${phone} {webhook} ${key} 13.75 && sleep 1 && "
            f"curl -sf -H 'Authorization: Bearer ${tokenInfra}' {api} | grep 13.75 >/dev/null",
            timeout=120,
        )

    with subtest("a report under a wrong key is ignored"):
        client.succeed(f"${phone} {webhook} wrongkeywrongkeywrongkeywrongkey 1.0")
        ha.wait_until_succeeds("journalctl -u home-assistant | grep -E 'unable to decrypt|CryptoError|Decryption failed' >/dev/null", timeout=30)
        code, body = read("${tokenDave}")
        assert code == "200" and json.loads(body)["current"]["lat"] == 13.75, (code, body)

    with subtest("both readers: position, battery, track"):
        client.succeed(f"${phone} {webhook} ${key} 13.8")
        client.wait_until_succeeds(
            f"curl -sf -H 'Authorization: Bearer ${tokenDave}' {api} | grep 13.8 >/dev/null", timeout=60
        )
        # the recorder commits every few seconds
        client.wait_until_succeeds(
            f"curl -sf -H 'Authorization: Bearer ${tokenInfra}' '{api}?hours=2' "
            "| python3 -c 'import json,sys; h=json.load(sys.stdin)[\"history\"]; "
            "assert {13.75, 13.8} <= {p[\"lat\"] for p in h}'",
            timeout=60,
        )
        code, body = read("${tokenInfra}", "?hours=2")
        assert code == "200", (code, body)
        b = json.loads(body)
        assert b["entity_id"] == "device_tracker.dave_pixel", b
        assert b["current"]["lat"] == 13.8 and b["current"]["battery"] == 64, b
        assert b["current"]["accuracy_m"] == 25 and b["current"]["age_s"] >= 0, b
        lats = [p["lat"] for p in b["history"]]
        assert 13.75 in lats and 13.8 in lats, lats

    with subtest("wrong or missing token: 401"):
        assert read("nope")[0] == "401"
        code = client.succeed(f"curl -sS -o /dev/null -w '%{{http_code}}' {api}")
        assert code == "401", code

    with subtest("outside sources: 403 even with a valid token"):
        assert read("${tokenInfra}", host="ha")[0] == "403"

    with subtest("GET only"):
        code = client.succeed(
            f"curl -sS -o /dev/null -w '%{{http_code}}' -X POST -H 'Authorization: Bearer ${tokenInfra}' {api}"
        )
        assert code == "405", code

    with subtest("reads are logged by reader name"):
        ha.succeed("journalctl -u home-assistant | grep 'location read by dave-hermes' >/dev/null")
  '';
}
