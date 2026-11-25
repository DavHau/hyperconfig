# The browser feature (nixosModules.browser). Isolation of the per-agent
# Camofox servers (modules/browser/camofox.nix): two agents,
# alice and bob. alice's first connection to her root-held port starts
# her server; her access key gates its routes. bob reaches neither her
# root-held port nor her backend, cannot read her key or profile store,
# and a listener he binds on her backend port while her server is down
# never receives her traffic.
#
# Downloads: browser_downloads (hyperhermes' addition to hermes' camofox
# plugin, ../../pkgs/hermes-camofox-plugin), called through hermes'
# tool registry against alice's real server and a local site, saves the
# files that a link, a form POST, a form POST redirected to another origin
# and a script start, and reports their sha256. It refuses paths outside
# the working directory, an existing file and a file over 50 MiB. Neither
# another camofox userId on her server nor bob sees her downloads, and
# closing the session deletes the server's copies.
#
# Captchas: browser_solve_captcha (the same plugin)
# drives the captcha plugin of alice's server (pkgs/camofox-browser) against a
# local 3x3 grid captcha, with a stand-in for the model that answers only a
# request carrying an image and no tools: the browser clicks the right tiles
# and Verify, and the tool reports solved; on a page without a captcha it
# reports no_captcha. Another camofox userId cannot solve on her tab.
#
# Vault: hermes' browser_vault save_login and fill (through the plugin's
# page backend, upstream since hermes v0.23.0) read the origin of alice's tab and
# fill a saved password into the site's login form through her server;
# on another origin the fill refuses and writes nothing. create_login
# (hermes-vault-generate-password.patch) generates a password on the
# site's signup form, saves it in her vault bound to that origin with the
# given identifier and fills the password and its confirmation with it,
# never returning it; on a page without a password field it saves nothing.
# Card frames (hermes-vault-payment-iframe-*.patch, the plugin's
# vault-frames.patch): a test card is filled into the card iframe a checkout
# embeds directly from the processor's origin (a second local site), and
# refused for the same frame from an origin the shop controls and for the
# processor frame nested in such a frame. Isolation: on a login page and in
# a card frame whose code hooks every built-in a fill script calls and walks
# fn.caller, the fills succeed and no hook sees a value (Camoufox's Xray
# sandbox, asserted by the vault-frames plugin); a card frame the checkout
# navigates to a hostile page right after the vault's value-free check gets
# nothing.
#
# Residential proxy (modules/browser/residential-proxy.nix): with
# browser.residentialProxy.url set, browser_residential is offered; the
# browser goes direct by default and through the proxy (a stand-in that
# marks the page with the proxy username) only after browser_residential,
# with the chosen country, and direct again after `off`.
#
# Parallel subagents (./concurrency.py, task-contexts.patch of the plugin):
# three children of one agent (delegate_task's child context, own task ids)
# browse at once, with managed persistence on. Each gets a context of its
# own (its cookie only, not the parent's or a sibling's), clicks a ref of its
# own snapshot onto its own next page, and through the residential proxy an
# exit session of its own, kept while a sibling switches off. A child joins
# the parent's cookies only with browser_context(shared). At task end the
# children's contexts are gone, saved state included; the profile's stays.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  hlib = self.lib;
  aliceUid = 1000;
  port = toString (hlib.camofoxPortFor "alice");
  backend = toString (hlib.camofoxBackendBase + aliceUid);
  dir = hlib.camofoxDir "alice";

  site = ./site.py;
  plugin = pkgs.callPackage ../../pkgs/hermes-camofox-plugin { };
  captchaSite = ./captcha-site.py;

  # Runs the driver as an agent with hermes' own interpreter, the agent's
  # camofox URL and key from its .env (as hermes reads them), the camofox
  # plugin the browser module links into her home, and her working
  # directory.
  driverScript =
    hermes: script: user: args:
    "runuser -u ${user} -- sh -c 'set -a; . ${hlib.stateDir user}/.hermes/.env; set +a; "
    + "HERMES_HOME=/home/${user}/hermes-test TERMINAL_CWD=${hlib.workspace user} CAMOFOX_PLUGIN=${plugin} CAMOFOX_PLUGIN_RECORD=${plugin.installRecord} "
    + "exec ${hermes.hermesVenv}/bin/python3 ${script} ${args}' 2>&1";
  # The vault driver resolves values, which alice's vault broker
  # (modules/core/vault-broker.nix) hands only to the main process of a
  # filling unit: it runs as one (vaultBroker.fillUnits), like her gateway.
  vaultDriverScript =
    hermes: script: user: args:
    "systemd-run --quiet --wait --pipe --collect --unit=hermes-vault-driver -p User=${user} -p Group=users "
    + "${pkgs.runtimeShell} -c 'set -a; . ${hlib.stateDir user}/.hermes/.env; set +a; "
    + "export HERMES_HOME=/home/${user}/hermes-test TERMINAL_CWD=${hlib.workspace user} CAMOFOX_PLUGIN=${plugin} CAMOFOX_PLUGIN_RECORD=${plugin.installRecord}; "
    + "exec ${hermes.hermesVenv}/bin/python3 ${script} ${args}' 2>&1";
  privateTmp = "/tmp/systemd-private-*-hermes-camofox-alice.service-*/tmp";
  agents = [
    "alice"
    "bob"
  ];
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-browser";

  # A container test (systemd-nspawn, no VM): the per-agent servers'
  # isolation is users, ports and the owner-match rules, no own kernel.
  containers.machine = {
    imports = [
      self.nixosModules.core
      self.nixosModules.browser
      ../container-pam.nix
    ];

    services.hyperhermes = {
      agents.alice.uid = aliceUid;
      agents.alice.vaultBroker.fillUnits = [ "hermes-vault-driver.service" ];
      agents.bob.uid = aliceUid + 1;
      browser = {
        enable = true;
        captchaSolver.baseUrl = "http://127.0.0.1:8766/v1";
        residentialProxy.url = "http://127.0.0.1:8768";
      };
    };

    # Core's agent unit, minus hermes itself: its preStart (state dirs,
    # .env, then camofox.nix's key hand-off) runs, the gateway does not.
    # Neither the dashboard nor the agent's pip venv plays a part here.
    systemd.services =
      lib.genAttrs (map (u: "hermes-agent-${u}") agents) (_: {
        serviceConfig = {
          Type = lib.mkForce "oneshot";
          ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
          Restart = lib.mkForce "no";
        };
      })
      // lib.genAttrs (map (u: "hermes-dashboard-${u}") agents ++ map (u: "hermes-python-venv-${u}") agents) (_: {
        enable = false;
      })
      // {

        download-site = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${site} 8765";
          };
        };
        # The card processor's origin for the vault's card-frame fill.
        card-site = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${site} 8767";
          };
        };
        residential-stub = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${./residential-stub.py} 8768";
          };
        };
        captcha-site = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python3 ${captchaSite} 8766";
          };
        };
      };

    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
    ];
    # Not a loopback name: Firefox sends those past any proxy.
    networking.hosts."127.0.0.1" = [ "residential-site.test" ];
  };

  testScript =
    { containers, ... }:
    let
      hermes = containers.machine.services.hyperhermes.package;
      driverOf = driverScript hermes;
      driver = driverOf ./downloads.py;
      captchaDriver = driverOf ./captcha.py;
      vaultDriver = vaultDriverScript hermes ./vault.py;
      residentialDriver = driverOf ./residential.py;
      concurrencyDriver = driverOf ./concurrency.py;
    in
    ''
    import hashlib
    import json
    import re

    machine.wait_for_unit("hermes-firewall.service")
    machine.wait_for_unit("hermes-camofox-fwd-alice.socket")

    with subtest("alice's agent gets her key and URL in her .env"):
        machine.succeed("systemctl start hermes-agent-alice.service")
        machine.succeed("test \"$(stat -c '%a %U' ${dir}/access-key)\" = '600 alice'")
        machine.succeed("test \"$(stat -c '%a %U' ${dir})\" = '700 alice'")
        key = machine.succeed("cat ${dir}/access-key").strip()
        env = machine.succeed("cat ${hlib.stateDir "alice"}/.hermes/.env")
        assert "CAMOFOX_URL=http://127.0.0.1:${port}\n" in env, env
        assert f"CAMOFOX_API_KEY={key}\n" in env, env
        machine.succeed("test \"$(readlink ${hlib.stateDir "alice"}/.hermes/plugins/camofox)\" = ${plugin}")
        machine.succeed("${pkgs.jq}/bin/jq -e '.camofox.catalog.tier == \"official\"' ${hlib.stateDir "alice"}/.hermes/plugins/.install-metadata.json")

    with subtest("every profile gets the link, over an upstream catalog install too"):
        profiles = "${hlib.stateDir "alice"}/.hermes/profiles"
        # bare: a profile without plugins/; caught: hermes' own install of
        # upstream's copy (a real directory) where the link belongs.
        machine.succeed(f"runuser -u alice -- mkdir -p {profiles}/bare {profiles}/caught/plugins/camofox")
        machine.succeed(f"runuser -u alice -- touch {profiles}/caught/plugins/camofox/plugin.yaml")
        machine.succeed("systemctl restart hermes-agent-alice.service")
        for p in ["bare", "caught"]:
            machine.succeed(f"test -L {profiles}/{p}/plugins/camofox")
            machine.succeed(f"test \"$(readlink {profiles}/{p}/plugins/camofox)\" = ${plugin}")
            machine.succeed(f"${pkgs.jq}/bin/jq -e '.camofox.pinned' {profiles}/{p}/plugins/.install-metadata.json")

    with subtest("alice's first connection starts her server"):
        machine.wait_until_succeeds("runuser -u alice -- curl -sf http://127.0.0.1:${port}/health", timeout=120)
        machine.succeed("systemctl is-active hermes-camofox-alice.service")
        machine.succeed("test \"$(stat -c %U /proc/$(systemctl show -P MainPID hermes-camofox-alice.service))\" = alice")

    tabs = "runuser -u alice -- curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{\"userId\":\"a\",\"sessionKey\":\"s\"}' "
    with subtest("routes need alice's key"):
        assert machine.succeed(tabs + "http://127.0.0.1:${port}/tabs").strip() == "401"
        assert machine.succeed(tabs + f"-H 'Authorization: Bearer {key}' http://127.0.0.1:${port}/tabs").strip() == "200"
        listed = json.loads(machine.succeed(f"runuser -u alice -- curl -sf -H 'Authorization: Bearer {key}' 'http://127.0.0.1:${port}/tabs?userId=a'"))
        assert len(listed["tabs"]) == 1, listed

    with subtest("browser_downloads saves alice's downloads, and only into her workspace"):
        machine.wait_for_unit("download-site.service")
        out = machine.succeed("${driver "alice" "owner http://127.0.0.1:8765 ${site}"}")
        print(out)
        assert "ALL PASSED" in out
        ids = json.loads(out.split("IDS: ", 1)[1].splitlines()[0])
        users = json.loads(out.split("USERS: ", 1)[1].splitlines()[0])
        # The workspace files belong to alice.
        machine.succeed("test \"$(stat -c %U ${hlib.workspace "alice"}/redirect.bin)\" = alice")

    with subtest("bob sees none of alice's downloads"):
        machine.succeed("systemctl start hermes-agent-bob.service")
        machine.succeed(f"echo '{json.dumps(ids)}' > /tmp/alice-ids.json && chmod 644 /tmp/alice-ids.json")
        out = machine.succeed("${driver "bob" "other http://127.0.0.1:8765 /tmp/alice-ids.json"}")
        print(out)
        assert "ALL PASSED" in out
        out = machine.succeed("runuser -u bob -- env CAMOFOX_URL=http://127.0.0.1:${port} CAMOFOX_API_KEY=x CAMOFOX_PLUGIN=${plugin} CAMOFOX_PLUGIN_RECORD=${plugin.installRecord} HERMES_HOME=/home/bob/hermes-test2 TERMINAL_CWD=/home/bob/ws ${hermes.hermesVenv}/bin/python3 ${./downloads.py} unreachable 2>&1")
        print(out)
        assert "ALL PASSED" in out

    with subtest("closing a session deletes the server's copies of its downloads"):
        copies = "ls ${privateTmp} | grep -c '^camofox-download-' || true"
        assert machine.succeed(copies).strip() == str(len(ids)), machine.succeed("ls ${privateTmp}")
        for u in users:
            machine.succeed(f"runuser -u alice -- curl -sf -X DELETE -H 'Authorization: Bearer {key}' http://127.0.0.1:${port}/sessions/{u}")
        assert machine.succeed(copies).strip() == "0", machine.succeed("ls ${privateTmp}")
        # Playwright's own copies (its artifacts dir) go with the browser context.
        assert machine.succeed("find ${privateTmp}/playwright-artifacts-* -type f").strip() == "", machine.succeed("ls -laR ${privateTmp}")

    with subtest("browser_solve_captcha solves alice's grid captcha in her browser"):
        machine.wait_for_unit("captcha-site.service")
        out = machine.succeed("${captchaDriver "alice" "captcha http://127.0.0.1:8766"}")
        print(out)
        assert "ALL PASSED" in out

    with subtest("the vault fills alice's saved or generated password in her browser, only on its origin"):
        out = machine.succeed("${vaultDriver "alice" "vault http://127.0.0.1:8765"}")
        print(out)
        assert "ALL PASSED" in out

    with subtest("the vault fills a test card only into the processor's card frame the checkout embeds directly"):
        machine.wait_for_unit("card-site.service")
        out = machine.succeed("${vaultDriver "alice" "card http://127.0.0.1:8765 http://localhost:8767"}")
        print(out)
        assert "ALL PASSED" in out
        # camofox-browser logs neither the fill script nor the card.
        assert "4242424242424242" not in machine.succeed("journalctl -u hermes-camofox-alice --no-pager")

    with subtest("page code that hooks the built-ins never sees the password or the card, nor after a frame hijack"):
        out = machine.succeed("${vaultDriver "alice" "hostile http://127.0.0.1:8765 http://localhost:8767"}")
        print(out)
        assert "ALL PASSED" in out
        assert "4242424242424242" not in machine.succeed("journalctl -u hermes-camofox-alice --no-pager")

    with subtest("browser_residential: direct by default, through the proxy only on request"):
        machine.wait_for_unit("residential-stub.service")
        assert "RESIDENTIAL_PROXY_URL=http://127.0.0.1:8768\n" in machine.succeed("cat ${hlib.stateDir "alice"}/.hermes/.env")
        out = machine.succeed("${residentialDriver "alice" "residential http://residential-site.test:8768"}")
        print(out)
        assert "ALL PASSED" in out

    with subtest("three parallel children: own contexts, own refs, own residential exits"):
        out = machine.succeed("${concurrencyDriver "alice" "concurrency http://residential-site.test:8768"}")
        print(out)
        assert "ALL PASSED" in out
        # Each child's context opened its own residential exit at the proxy.
        rlog = machine.succeed("journalctl -u hermes-camofox-alice --no-pager -o cat | grep 'residential session' || true")
        assert len(set(re.findall(r'exitSession":"([0-9a-f]{10})', rlog))) >= 3, rlog
        # The children's saved state is gone; the profile's own is kept.
        uids = json.loads(out.split("CHILD_UIDS: ", 1)[1].splitlines()[0])
        profile_uid = out.split("PROFILE_UID: ", 1)[1].splitlines()[0]
        for u in uids:
            d = hashlib.sha256(u.encode()).hexdigest()[:32]
            machine.fail(f"test -e ${dir}/profiles/{d}")
        machine.succeed("systemctl restart hermes-camofox-alice.service")
        d = hashlib.sha256(profile_uid.encode()).hexdigest()[:32]
        machine.succeed(f"test -s ${dir}/profiles/{d}/storage-state.json")
        machine.wait_until_succeeds("runuser -u alice -- curl -sf http://127.0.0.1:${port}/health", timeout=120)

    with subtest("bob reaches neither alice's port nor her backend"):
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${port}/health")
        machine.fail("runuser -u bob -- curl -s --max-time 10 http://127.0.0.1:${backend}/health")

    with subtest("bob reads neither alice's key nor her profile store"):
        machine.fail("runuser -u bob -- cat ${dir}/access-key")
        machine.fail("runuser -u bob -- ls ${dir}/profiles")
        machine.fail("runuser -u bob -- cat /proc/$(systemctl show -P MainPID hermes-camofox-alice.service)/environ")

    with subtest("a listener bob binds on alice's backend gets none of her traffic"):
        machine.succeed("systemctl stop hermes-camofox-alice.service")
        # Stopping saves the profiles' cookies, owner-only.
        machine.succeed("test \"$(stat -c '%a %U' ${dir}/profiles/*/storage-state.json | sort -u)\" = '600 alice'")
        machine.fail("journalctl -u hermes-camofox-alice --no-pager | grep -q 'failed to persist'")
        machine.succeed("systemd-run --uid=bob --unit=squat ${pkgs.python3}/bin/python3 -m http.server ${backend} --bind 127.0.0.1")
        # root may dial any gated port; bob's own dial is rejected too.
        machine.wait_until_succeeds("curl -sf -o /dev/null http://127.0.0.1:${backend}/", timeout=60)
        served = "journalctl -u squat --no-pager | grep -c 'GET /'"
        before = machine.succeed(served).strip()
        machine.fail(f"runuser -u alice -- curl -sf --max-time 30 -H 'Authorization: Bearer {key}' 'http://127.0.0.1:${port}/tabs?userId=a'")
        assert machine.succeed(served).strip() == before
        machine.wait_until_succeeds("journalctl --no-pager | grep -q 'refusing: backend 127.0.0.1:${backend} is owned by uid 1001'", timeout=60)
  '';
}
