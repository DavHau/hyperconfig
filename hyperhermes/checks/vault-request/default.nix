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
#    handle. alice's vault lists the item (metadata only), held by her vault
#    broker; the card number is in no request file, no journal and not in
#    the vault file in plain;
#  - the same link again: refused (single use);
#  - bob, who owns another agent, is refused by alice's dashboard sign-in
#    and stays outside the page; signed in to his own dashboard, alice's
#    link on his host finds no request (requests are per agent), and his
#    session replayed at alice's host is refused there;
#  - an expired, a cancelled request; bob's own page socket is not alice's;
#  - the owner's vault page (modules/vault-request/owner.nix) on the front
#    door: alice's dashboard's /vault sends the browser there; without a
#    session it goes to the front door's sign-in; bob (signed in, not an
#    owner of alice's agent) gets 403; alice sees the card as brand and last
#    4 only and a login her agent made, reveals its password (no-store,
#    that response only), cannot reveal the card, and deletes the login
#    after a confirmation; cross-site and same-site posts and a wrong form
#    token are refused; every reveal and delete is in the broker's journal,
#    without a value;
#  - alice's uid gets nothing through the new path: the broker refuses the
#    owner operations to her (and to root), she cannot reach the page's
#    socket; the agent's vault_request `where` names the page;
#  - root's `hermes-vault` CLI lists (card: last 4) and shows a login,
#    audited the same way; alice cannot run it;
#  - no password or card number in nginx's logs, the journal or nginx's
#    temp files.
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
  frontDoor = "front.localhost";
  front = "http://${frontDoor}:${toString port}";
  aliceHome = "${hlib.stateDir "alice"}/.hermes";
  # The tool as alice's agent runs it (the environment its managed .env
  # sets), from the link in its plugins/.
  tool = pkgs.writeShellScript "vault-request-tool" ''
    exec runuser -u alice -- env HERMES_HOME=${aliceHome} \
      HERMES_VAULT_REQUEST_DIR=${hlib.stateDir "alice"}/vault-requests \
      HERMES_VAULT_REQUEST_URL=${origin "alice"} \
      HERMES_VAULT_OWNER_PAGE=${origin "alice"}/vault \
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
        clients = lib.genAttrs [ "hermes" "hermes-alice" "hermes-bob" ] (id: {
          secretFile = "${secrets}/${id}";
        });
        frontDoor = {
          host = frontDoor;
          cookieSecretFile = "${secrets}/front-door-cookie";
        };
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
            "oauth2-proxy.service"
            "hermes-agent-alice.service"
            "hermes-agent-bob.service"
          ];
          requiredBy = [
            "dex.service"
            "oauth2-proxy.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 700 ${secrets}
            echo -n 0123456789abcdef0123456789abcdef > ${secrets}/front-door-cookie
            for id in hermes hermes-alice hermes-bob; do
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

    def owner(agent, account, mode, *extra):
        out = machine.succeed(
            f"${python}/bin/python3 ${./owner.py} ${front} http://{agent}.${domain}:${toString port} "
            f"{agent} {account}@${domain} {account}-password {mode} {' '.join(extra)}"
        )
        print(out)
        return json.loads(out.strip().splitlines()[-1])

    def raw(user, request):
        out = machine.succeed(f"runuser -u {user} -- ${hermesPackage.hermesVenv}/bin/python3 ${./tool.py} "
                              f"/run/hermes-vault/alice.sock --raw={shlex.quote(json.dumps(request))}")
        return json.loads(out.strip().splitlines()[-1])

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
        # in alice's vault broker (modules/core/vault-broker.nix), out of her uid's reach
        machine.fail("test -e ${aliceHome}/vault/vault.json.enc")
        machine.succeed("test -s /var/lib/private/hermes-vault/alice/home/vault/vault.json.enc")
        machine.fail("runuser -u alice -- ls /var/lib/private/hermes-vault/alice")
        machine.fail("grep -rq 4111111111111111 /var/lib/private/hermes-vault ${hlib.stateDir "alice"}")
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
        # renew: the same link works again for another 30 minutes; a cancelled one is not revived.
        renewed = call({"action": "renew", "request_id": late["request_id"]})
        assert renewed["success"] and renewed["state"] == "pending" and renewed["expires_in_seconds"] > 1700, renewed
        assert renewed["link"].endswith("/vault/" + late["request_id"]), renewed
        code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' --unix-socket /run/hermes-vault-request/alice.sock http://x/vault/{late['request_id']}")
        assert code != "410", code
        assert not call({"action": "renew", "request_id": gone["request_id"]})["success"]
        assert call({"action": "status", "request_id": gone["request_id"]})["state"] == "cancelled"
        # too old to renew: past a day since it was created
        machine.succeed(f"runuser -u alice -- ${pkgs.jq}/bin/jq '.created = 1 | .expires = 1' {path} > /tmp/old.json")
        machine.succeed(f"runuser -u alice -- cp /tmp/old.json {path}")
        old = call({"action": "renew", "request_id": late["request_id"]})
        assert not old["success"] and "too old" in old["error"], old

    login_id = tool("--add-login")["id"]
    password = "Gen3rated-Pa55word-x9"

    with subtest("the agent learns the owner page's address, and gets nothing through its path"):
        where = call({"action": "where"})
        assert where["owner_page"] == "${origin "alice"}/vault", where
        # a host without the page: the tool names none
        none = json.loads(machine.succeed(
            "runuser -u alice -- env HERMES_HOME=${aliceHome} ${hermesPackage.hermesVenv}/bin/python3 ${./tool.py} "
            f"${aliceHome}/plugins/vault-request {shlex.quote(json.dumps({'action': 'where'}))}").strip().splitlines()[-1])
        assert none["owner_page"] is None and "do not name or guess" in none["next"], none
        assert "HERMES_VAULT_OWNER_PAGE=${origin "alice"}/vault" in env, env
        for op in ("owner_list", "owner_reveal", "owner_remove"):
            req = {"op": op, "account": "alice", "store": "home", "item_id": login_id}
            for user in ("alice", "root"):
                out = raw(user, req) if user == "alice" else json.loads(machine.succeed(
                    f"${hermesPackage.hermesVenv}/bin/python3 ${./tool.py} /run/hermes-vault/alice.sock "
                    f"--raw={shlex.quote(json.dumps(req))}").strip().splitlines()[-1])
                assert out == {"ok": False, "error": "only the owner's vault page may do this"}, (user, op, out)
        # the login is still there: the remove above was refused
        assert login_id in [i["id"] for i in tool("--vault")]
        machine.succeed("stat -c '%U %G %a' /run/hermes-vault-owner/alice.sock | grep -qx 'root nginx 660'")
        machine.fail("runuser -u alice -- curl -s --unix-socket /run/hermes-vault-owner/alice.sock http://x/vault/alice/")
        # the page runs under a uid of its own
        machine.succeed("systemctl start hermes-vault-owner-alice.socket")
        machine.succeed("curl -s -H 'X-Hermes-Account: alice' --unix-socket /run/hermes-vault-owner/alice.sock http://x/vault/alice/ >/dev/null")
        pid = machine.succeed("systemctl show -P MainPID hermes-vault-owner-alice").strip()
        uid = machine.succeed(f"stat -c %u /proc/{pid}").strip()
        assert uid not in ("0", machine.succeed("id -u alice").strip(), machine.succeed("id -u bob").strip()), uid
        assert "REFUSED" not in machine.succeed("journalctl -u hermes-vault-alice -o cat | grep owner- || true")

    with subtest("root's hermes-vault lists and shows, audited; alice cannot run it"):
        listed = machine.succeed("hermes-vault alice list")
        print(listed)
        assert "Visa ****1111" in listed and "4111111111111111" not in listed and "alice@shop.example.com" in listed, listed
        assert password not in listed
        shown = machine.succeed("hermes-vault alice show 'Shop account'")
        assert f"password: {password}" in shown and "alice@shop.example.com" in shown, shown
        card = machine.succeed("hermes-vault alice show 'Test card'")
        assert "Visa ****1111" in card and "4111111111111111" not in card, card
        machine.wait_until_succeeds(f"journalctl -t hermes-vault-alice _UID=0 -o cat | grep -q 'owner-reveal {login_id} kind=login store=home account=root via=cli'")
        # a card's show prints nothing secret: no audit line
        assert "owner-reveal" not in machine.succeed("journalctl -t hermes-vault-alice -o cat | grep kind=payment || true")
        machine.fail("runuser -u alice -- hermes-vault alice list")
        machine.fail("hermes-vault alice --profile Bad.Name list")
        assert "no items in profile nope" in machine.succeed("hermes-vault alice --profile nope list")
        # an agent-chosen label reaches neither root's terminal as an escape sequence nor the
        # journal as a forged audit line
        evil = raw("alice", {"op": "add_item", "home": "${aliceHome}", "kind": "login", "secret": {"password": "x", "identifier_type": "username", "identifier": "\x1b[2Jroot"}, "origin": "https://evil.example.com",
                             "label": "\x1b]52;c;ZWNobyBwd24K\x07Evil\nowner-reveal vault_0 kind=login store=home account=dave via=page"})
        assert evil["ok"], evil
        # a lone surrogate would crash the listing (and blank the owner's page)
        evil2 = raw("alice", {"op": "add_item", "home": "${aliceHome}", "kind": "login", "origin": "https://evil.example.com",
                              "secret": {"password": "y", "identifier_type": "username", "identifier": "e"}, "label": "Evil2 \ud800\u202e"})
        assert evil2["ok"], evil2
        for cmd, code, want in (("list", 0, "Evil2"), ("show ZWNobyBwd24K", 0, "password: x"), ("show vil", 2, "Evil2")):
            machine.succeed(f"rc=0; hermes-vault alice {cmd} > /tmp/o 2>&1 || rc=$?; test $rc = {code}")
            text = machine.succeed("cat /tmp/o")
            assert want in text, (cmd, text)
            od = machine.succeed("od -An -c /tmp/o")
            assert "033" not in od and "007" not in od and "342 200 256" not in od, (cmd, od)
        for e in (evil, evil2):
            assert raw("alice", {"op": "remove_item", "home": "${aliceHome}", "item_id": e["result"]["id"]})["result"] is True
        assert "owner-reveal vault_0" not in machine.succeed("journalctl -u hermes-vault-alice -o cat | grep '^owner-' || true")
        # the agent's refused owner ops above left a trace
        machine.succeed(f"journalctl -u hermes-vault-alice -o cat | grep -q 'REFUSED owner_list uid={machine.succeed('id -u alice').strip()}'")
        # it left no root-owned file in the broker's store
        assert machine.succeed("find /var/lib/private/hermes-vault/alice -user root").strip() == ""

    with subtest("the owner's vault page"):
        owner("alice", "alice", "anonymous")
        owner("alice", "bob", "outsider", login_id)
        owner("alice", "alice", "owner", login_id)
        journal = machine.succeed("journalctl -u hermes-vault-alice -o cat")
        assert f"owner-reveal {login_id} kind=login store=home account=alice via=page" in journal, journal
        assert f"owner-delete {login_id} kind=login store=home account=alice via=page removed=True" in journal, journal
        assert login_id not in [i["id"] for i in tool("--vault")]
        assert [i["label"] for i in tool("--vault")] == ["Test card"]

    with subtest("no value in the logs"):
        machine.succeed("journalctl -o cat > /tmp/journal")
        for value in (password, "4111111111111111"):
            machine.fail(f"grep -qF {value} /tmp/journal")
            machine.fail(f"grep -rqF {value} /var/log/nginx /var/cache/nginx")

    with subtest("only nginx (and root) can connect to the page sockets"):
        machine.fail("runuser -u bob -- curl -s --unix-socket /run/hermes-vault-request/alice.sock http://x/")
        machine.fail("runuser -u alice -- curl -s --unix-socket /run/hermes-vault-request/bob.sock http://x/")
  '';
}
