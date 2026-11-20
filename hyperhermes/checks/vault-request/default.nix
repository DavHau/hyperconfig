# The vault-request module end to end, in one container (systemd-nspawn,
# no VM): dex (sso's local issuer) with alice and bob, each owning one
# agent, both agents' gateways and dashboards running, nginx in local mode.
#
#  - alice's agent creates a request through its tool (the plugin from the
#    link its gateway's preStart made) and gets http://alice.<domain>/vault/<id>;
#  - without a session the page sends the browser to the dashboard's
#    sign-in; alice signs in at dex and opens the link as a cross-site
#    navigation (a link from a chat app): the form for a card, no-store,
#    CSP, no framing, the card autocomplete hints;
#  - cross-site and same-site posts are refused before the page, a wrong
#    form token by the page; then a TEST card (4111 1111 1111 1111) with a
#    real browser's headers is saved, and the tool's `wait` returns its
#    handle. alice's vault lists the item (metadata only); the card number
#    is in no request file, no journal and not in the vault file in plain;
#  - the same link again: refused (single use);
#  - bob, who owns another agent, is refused by alice's dashboard sign-in
#    and stays outside the page; signed in to his own dashboard, alice's
#    link on his host finds no request (requests are per agent), and his
#    session replayed at alice's host is refused there;
#  - an expired, a cancelled request; bob's own page socket is not alice's.
{
  pkgs,
  self,
  hermesPackage,
}:
let
  inherit (pkgs) lib;
  hlib = self.lib;
  domain = "hermes.localhost";
  port = 8473;
  secrets = "/var/lib/vault-request-secrets";
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.requests
  ]);
  origin = agent: "http://${agent}.${domain}:${toString port}";
  aliceHome = "${hlib.stateDir "alice"}/.hermes";
  # The tool as alice's agent runs it (the environment its managed .env
  # sets), from the link in its plugins/.
  tool = pkgs.writeShellScript "vault-request-tool" ''
    exec runuser -u alice -- env HERMES_HOME=${aliceHome} \
      HERMES_VAULT_REQUEST_DIR=${hlib.stateDir "alice"}/vault-requests \
      HERMES_VAULT_REQUEST_URL=${origin "alice"} \
      ${hermesPackage.hermesVenv}/bin/python3 ${./tool.py} ${aliceHome}/plugins/vault-request "$1"
  '';
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-vault-request";

  containers.machine = {
    imports = [
      self.nixosModules.default
      ../container-pam.nix
    ];
    environment.systemPackages = [
      pkgs.curl
      python
    ];

    services.hyperhermes = {
      package = hermesPackage;
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
        clients = lib.genAttrs [ "hermes-alice" "hermes-bob" ] (id: {
          secretFile = "${secrets}/${id}";
        });
        dex.users = lib.genAttrs [ "alice" "bob" ] (account: {
          passwordHashFile = "${secrets}/${account}.hash";
        });
      };
      dashboards.enable = true;
    };

    systemd.services = lib.mkMerge [
      {
        vault-request-secrets = {
          wantedBy = [ "multi-user.target" ];
          before = [
            "dex.service"
            "hermes-agent-alice.service"
            "hermes-agent-bob.service"
          ];
          requiredBy = [ "dex.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 700 ${secrets}
            for id in hermes-alice hermes-bob; do
              echo -n "client-secret-$id" > ${secrets}/$id
            done
            for user in alice bob; do
              ${python}/bin/python3 -c "import bcrypt; print(bcrypt.hashpw(b'$user-password', bcrypt.gensalt(10)).decode())" \
                > ${secrets}/$user.hash
            done
          '';
        };
      }
      (lib.genAttrs [ "hermes-dashboard-alice" "hermes-dashboard-bob" ] (_: {
        after = [
          "dex.service"
          "nginx.service"
        ];
      }))
    ];
  };

  testScript = ''
    import json
    import shlex

    def browser(agent, account, rid, mode, *extra):
        out = machine.succeed(
            f"${python}/bin/python3 ${./browser.py} http://{agent}.${domain}:${toString port} "
            f"{account}@${domain} {account}-password {rid} {mode} {' '.join(extra)}"
        )
        print(out)
        return json.loads(out.strip().splitlines()[-1])

    def tool(arg):
        return json.loads(machine.succeed(f"${tool} {shlex.quote(arg)}").strip().splitlines()[-1])

    def call(args):
        out = tool(json.dumps(args))
        print(out)
        return out

    start_all()
    machine.wait_for_unit("dex.service")
    machine.wait_for_unit("nginx.service")
    for agent in ("alice", "bob"):
        # the gateway's preStart links the plugin (the gateway itself needs
        # no model here)
        machine.wait_until_succeeds(f"test -L ${hlib.stateRoot}/{agent}/state/.hermes/plugins/vault-request", timeout=180)
        machine.wait_for_unit(f"hermes-dashboard-{agent}.service")
        machine.wait_until_succeeds(f"curl -sf http://{agent}.${domain}:${toString port}/api/status", timeout=180)

    with subtest("the agent has the tool, the skill and the page's settings"):
        reg = tool("--register")
        assert reg == {"name": "vault_request", "toolset": "vault-request", "available": True}, reg
        # and hermes' own loader, as a session of alice's agent starts it
        loaded = tool("--hermes")
        assert loaded == {"enabled": True, "tools": 1, "error": None, "registered": True}, loaded
        config = machine.succeed("cat ${aliceHome}/config.yaml")
        assert "vault-request" in config, config
        managed = machine.succeed("systemctl show -p Environment hermes-agent-alice")
        managed_dir = [w.split("=", 1)[1] for w in managed.split() if w.startswith("HERMES_MANAGED_DIR=")][0]
        env = machine.succeed(f"cat {managed_dir}/.env")
        assert "HERMES_VAULT_REQUEST_URL=${origin "alice"}" in env, env
        assert "agent-skill-vault-request/share/skills" in machine.succeed(f"cat {managed_dir}/config.yaml")
        assert machine.succeed("stat -c '%U %a' ${hlib.stateDir "alice"}/vault-requests").strip() == "alice 700"
        assert machine.succeed("stat -c '%U %G %a' /run/hermes-vault-request/alice.sock").strip() == "root nginx 660"

    with subtest("bad requests are refused by the tool"):
        assert not call({"action": "create", "kind": "payment", "label": "x", "origin": "shop.example.com"})["success"]
        assert not call({"action": "create", "kind": "crypto", "label": "x", "origin": "https://a.example"})["success"]
        # a login stays bound to its exact site: it needs one (cards and addresses fill on any site)
        assert not call({"action": "create", "kind": "login", "label": "x"})["success"]
        hint = call({"action": "create", "kind": "address", "label": "Home", "origin": "https://shop.example.com/a"})
        assert hint["success"] and hint["origin"] == "https://shop.example.com", hint
        assert call({"action": "cancel", "request_id": hint["request_id"]})["state"] == "cancelled"
        assert not call({"action": "status", "request_id": "..%2f" + "x" * 30})["success"]

    # A card has no site (hermes-vault-payment-any-site.patch): usable anywhere, each fill confirmed.
    req = call({"action": "create", "kind": "payment", "label": "Card for shop.example.com",
                "reason": "checkout needs a card"})
    assert req["success"] and req["state"] == "pending" and req["origin"] == "", req
    rid = req["request_id"]
    assert req["link"] == f"${origin "alice"}/vault/{rid}", req
    assert "token" not in json.dumps(req), req

    with subtest("without a session the page sends the browser to the sign-in"):
        browser("alice", "alice", rid, "anonymous")

    with subtest("bob, owner of another agent, cannot use alice's link"):
        browser("alice", "bob", rid, "outsider")
        browser("bob", "bob", rid, "foreign", "${origin "alice"}")

    with subtest("alice saves a test card; cross-site posts and reuse are refused"):
        browser("alice", "alice", rid, "save")
        done = call({"action": "wait", "request_id": rid, "timeout_seconds": 5})
        assert done["state"] == "done" and done["handle"].startswith("vault_"), done
        items = tool("--vault")
        print(items)
        assert [(i["id"], i["kind"], i["label"], i["origin"]) for i in items] == [
            (done["handle"], "payment", "Test card", None)], items
        assert machine.succeed("stat -c '%U %a' ${aliceHome}/vault/vault.json.enc ${aliceHome}/vault/vault.key").split() == ["alice", "600", "alice", "600"]
        machine.fail("grep -rq 4111111111111111 ${aliceHome}/vault ${hlib.stateDir "alice"}/vault-requests")
        machine.succeed("journalctl -o cat > /tmp/journal && test -s /tmp/journal")
        machine.fail("grep -qF 4111111111111111 /tmp/journal")
        # (the logs exist: a grep of a missing dir fails too)
        machine.succeed("test -s /var/log/nginx/access.log && test -d /var/cache/nginx")
        machine.fail("grep -rq 4111111111111111 /var/log/nginx /var/cache/nginx")

    with subtest("expired and cancelled requests"):
        gone = call({"action": "create", "kind": "address", "label": "Home", "origin": "https://shop.example.com"})
        assert call({"action": "cancel", "request_id": gone["request_id"]})["state"] == "cancelled"
        late = call({"action": "create", "kind": "login", "label": "Shop", "origin": "https://shop.example.com"})
        path = f"${hlib.stateDir "alice"}/vault-requests/{late['request_id']}.json"
        machine.succeed(f"runuser -u alice -- ${pkgs.jq}/bin/jq '.expires = 1' {path} > /tmp/late.json")
        machine.succeed(f"runuser -u alice -- cp /tmp/late.json {path}")
        assert call({"action": "status", "request_id": late["request_id"]})["state"] == "expired"
        code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' --unix-socket /run/hermes-vault-request/alice.sock http://x/vault/{late['request_id']}")
        assert code == "410", code

    with subtest("only nginx (and root) can connect to the page sockets"):
        machine.fail("runuser -u bob -- curl -s --unix-socket /run/hermes-vault-request/alice.sock http://x/")
        machine.fail("runuser -u alice -- curl -s --unix-socket /run/hermes-vault-request/bob.sock http://x/")
  '';
}
