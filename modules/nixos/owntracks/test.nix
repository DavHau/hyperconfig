# ./home-assistant.nix in a NixOS container (checks.x86_64-linux.owntracks):
# Home Assistant with the seeded OwnTracks and location_api config entries
# (./seed.py), the test's stand-ins for the clan vars. `client` plays the
# phone (an OwnTracks HTTP-mode report, secretbox-encrypted, X-Limit-U/D
# headers as OwnTracks for Android sends them) and the agents (bearer
# tokens). Covered: the encrypted report lands as device_tracker.dave_pixel;
# a report under a wrong key is ignored; the reader gets position, battery
# and track; a wrong or missing token is 401; a source outside `sources`
# (HA's own loopback) is 403 even with a valid token; the endpoint is
# GET-only; a restart keeps exactly one config entry per domain; reads and
# rejected reads are logged at HA's default level (WARNING, as on cm-pi);
# the skill's own commands (./skill, rendered as ./agents.nix does) work
# and put the token into no process's command line (execve traced, /proc
# sampled by another user), while the old `Bearer $(cat ...)` form does.
# edi's nginx front (./edi.nix) is not covered here: edi's build checks
# its nginx.conf with gixy only, nginx -t runs at its start/reload.
{ pkgs }:
let
  inherit (pkgs) lib;
  key = "0123456789abcdef0123456789abcdef";
  webhookId = "testwebhook0123456789abcdef0123456789abcdef0123456789abcdef01234";
  tokenInfra = "infra-token-0123456789";
  tokenDave = "dave-hermes-token-0123456789";
  sha = s: builtins.hashString "sha256" s;
  agentToken = "/run/agent/location-token";
  skillText = lib.replaceStrings [ "@TOKEN_FILE@" ] [ agentToken ] (builtins.readFile ./skill/SKILL.md);
  # the skill's bash block, one command per entry, aimed at the test's HA
  skillCommands = pkgs.writeText "skill-commands.json" (
    builtins.toJSON (
      let
        block = builtins.elemAt (builtins.split "```bash\n|```\n" skillText) 2;
        joined = lib.replaceStrings [ "\\\n" ] [ " " ] block;
        lines = lib.filter (l: l != "") (lib.splitString "\n" joined);
      in
      map (
        l:
        lib.replaceStrings [ "cm-pi.d:8123" ] [ "ha:8123" ] (builtins.head (lib.splitString "  #" l))
      ) lines
    )
  );
  # sees other users' command lines as on som (no hidepid)
  spy = pkgs.writers.writePython3 "cmdline-spy" { } ''
    import glob
    import os
    import sys
    import time

    # from a file: in any argv it would match itself
    secret = open(sys.argv[2], "rb").read().strip()
    me = f"/proc/{os.getpid()}/cmdline"
    curls = leaked = 0
    end = time.time() + float(sys.argv[1])
    while time.time() < end:
        for f in glob.glob("/proc/[0-9]*/cmdline"):
            if f == me:
                continue
            try:
                c = open(f, "rb").read()
            except OSError:
                continue
            curls += c.startswith(b"curl\0") and b"hyper_location" in c
            leaked += secret in c
    print(curls, leaked)
  '';
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
      pkgs.strace
    ];
    users.users.agent = {
      isNormalUser = true;
      uid = 1001;
    };
    users.users.spy = {
      isNormalUser = true;
      uid = 1002;
    };
    systemd.tmpfiles.rules = [
      "d /run/agent 0700 agent users -"
      "f+ ${agentToken} 0400 agent users - ${tokenDave}"
    ];
  };

  testScript = ''
    import json
    import re
    import shlex

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

    with subtest("reads and rejections are logged at HA's default level"):
        journal = ha.succeed("journalctl -u home-assistant")
        assert re.search(r"location read by dave-hermes from (192\.168\.1\.\d+|2001:db8:1::[0-9a-f:]+)\s", journal), journal[-3000:]
        assert re.search(r"location read rejected \(401, token\) from (192\.168\.1\.\d+|2001:db8:1::[0-9a-f:]+)\s", journal), journal[-3000:]
        assert re.search(r"location read rejected \(403, source\) from (127\.0\.0\.1|::1)", journal), journal[-3000:]

    with subtest("the skill's commands keep the token off every command line"):
        skill = open("${pkgs.writeText "dave-location-SKILL.md" skillText}").read()
        assert not re.search(r"Bearer \$[({]|-H\s*[\"'][^\"'\n]*\$\(", skill), "token-on-argv pattern in the skill"
        cmds = json.loads(open("${skillCommands}").read())
        assert len(cmds) == 2 and all(c.startswith("curl ") for c in cmds), cmds
        assert all("--variable 'token@${agentToken}'" in c and "$" not in c for c in cmds), cmds
        for c in cmds:
            out = client.succeed(f"runuser -u agent -- bash -c {shlex.quote(c)}")
            assert json.loads(out)["current"]["lat"] == 13.8, out
        # every exec'd process's argv, deterministically
        def traced(cmd):
            client.succeed(
                f"strace -f -qq -s 4096 -e trace=execve -o /tmp/trace "
                f"runuser -u agent -- bash -c {shlex.quote(cmd)} >/dev/null"
            )
            return client.succeed("cat /tmp/trace")
        for c in cmds:
            t = traced(c)
            assert "execve(" in t and "hyper_location" in t, t
            assert "${tokenDave}" not in t, "token in an argv: " + t
        # the old form leaks: proves the trace would catch it
        old = "curl -fsS -H \"Authorization: Bearer $(cat ${agentToken})\" http://ha:8123/api/hyper_location"
        assert "${tokenDave}" in traced(old)
        # another user polling /proc during the calls sees curl, not the token
        # (and does see it with the old form: the probe works)
        client.succeed("install -m 0444 ${agentToken} /tmp/spy-secret")
        def spied(cmd):
            client.succeed(
                "runuser -u spy -- ${spy} 6 /tmp/spy-secret > /tmp/spy & "
                f"for i in $(seq 100); do runuser -u agent -- bash -c {shlex.quote(cmd)} >/dev/null; done; wait"
            )
            return tuple(map(int, client.succeed("cat /tmp/spy").split()))
        curls, leaked = spied(cmds[0])
        assert curls > 0 and leaked == 0, (curls, leaked)
        curls, leaked = spied(old)
        assert curls > 0 and leaked > 0, (curls, leaked)
  '';
}
