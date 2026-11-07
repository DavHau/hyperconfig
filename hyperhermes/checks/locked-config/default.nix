# lockedConfig end to end, in a NixOS container (private network) with
# the dashboards behind dex the way ../local-sso runs them: alice's agent
# is locked. As alice's uid (./attack.py), every write, replace, delete,
# chmod and rename of what hermes reads (.env, .op.env, config.yaml,
# plugins/ and the other pinned entries, $HERMES_HOME itself) fails, and
# what can be written (names hermes does not read, .container-mode, the
# workspace, ~/.hermes) is planted with dashboard basic-auth keys,
# gate-weakening keys, a dashboard_auth plugin and, for claude-auth's
# bootstrap (enabled here, as on som), modules in ~/.hermes/patches.
# After a restart of gateway and dashboard none of it has an effect: the
# dashboard offers only the OIDC provider, refuses a basic-auth login,
# the planted plugin never loads, no planted patches module is imported,
# and the OIDC sign-in (which needs the client secret, a secretEnv
# credential) still ends on a gated API call. The `hermes` CLI,
# called with a poisoned environment, still answers from the locked
# config through a stub model endpoint that sees the secretEnv provider
# key. A runtime config change does not persist, names the agent took
# before their pins existed are taken back, and another account cannot
# read the .env.
{
  pkgs,
  self,
  hermesPackage,
}:
let
  hlib = self.lib;
  domain = "hermes.localhost";
  port = 8473;
  origin = "http://alice.${domain}:${toString port}";
  containerAddress = "10.233.1.2";
  secrets = "/var/lib/locked-config-secrets";
  llmPort = 9999;
  llmRecord = "/var/lib/fake-llm/auth";
  hermesHome = hlib.lockedHermesHome "alice";
  workspace = hlib.workspace "alice";
  python = pkgs.python3.withPackages (ps: [
    ps.bcrypt
    ps.requests
  ]);
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-locked-config";

  nodes.machine = {
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;

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
          pkgs.curl
          pkgs.e2fsprogs
        ];

        users.users.eve.isNormalUser = true;

        services.hyperhermes = {
          package = hermesPackage;
          # Its bootstrap puts a patches dir first on sys.path in every
          # hermes process; ~/.hermes/patches must not be it.
          claudeAuth.enable = true;
          pythonPackages = _: [ ];
          initialModel = {
            provider = "custom";
            base_url = "http://127.0.0.1:${toString llmPort}/v1";
            default = "fake-model";
          };
          agents.alice = {
            uid = 1001;
            lockedConfig = true;
            # hermes sends OPENAI_API_KEY to the endpoint OPENAI_BASE_URL
            # names (hermes_cli/runtime_provider.py).
            environment.OPENAI_BASE_URL = "http://127.0.0.1:${toString llmPort}/v1";
            secretEnv.OPENAI_API_KEY = "${secrets}/openai";
          };
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
          };
          dashboards.enable = true;
        };

        systemd.services.locked-config-secrets = {
          wantedBy = [ "multi-user.target" ];
          before = [
            "dex.service"
            "hermes-locked-alice.service"
          ];
          requiredBy = [
            "dex.service"
            "hermes-locked-alice.service"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 700 ${secrets}
            echo client-secret-alice > ${secrets}/hermes-alice
            echo sk-locked-test > ${secrets}/openai
            ${python}/bin/python3 -c "import bcrypt; print(bcrypt.hashpw(b'alice-password', bcrypt.gensalt(10)).decode())" \
              > ${secrets}/alice.hash
          '';
        };

        systemd.services.fake-llm = {
          wantedBy = [ "multi-user.target" ];
          before = [ "hermes-agent-alice.service" ];
          serviceConfig = {
            StateDirectory = "fake-llm";
            ExecStart = "${pkgs.python3}/bin/python3 ${./fake-llm.py} ${toString llmPort} ${llmRecord}";
          };
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

    def inside(cmd):
        return machine.succeed(f"nixos-container run hh -- {cmd}")

    def inside_fails(cmd):
        return machine.fail(f"nixos-container run hh -- {cmd}")

    def as_alice(cmd):
        return inside(f"runuser -u alice -- {cmd}")

    def restart_agent():
        inside("systemctl restart hermes-agent-alice.service hermes-dashboard-alice.service")
        machine.wait_until_succeeds(
            "nixos-container run hh -- systemctl is-active hermes-agent-alice.service hermes-dashboard-alice.service"
        )
        machine.wait_until_succeeds("curl -sf ${origin}/api/status", timeout=180)

    start_all()
    machine.wait_for_unit("container@hh.service")
    machine.wait_until_succeeds(
        "nixos-container run hh -- systemctl is-active dex.service nginx.service "
        "hermes-locked-alice.service hermes-agent-alice.service hermes-dashboard-alice.service",
        timeout=300,
    )
    machine.wait_until_succeeds("curl -sf ${origin}/api/status", timeout=180)

    pinned_files = (".env", "config.yaml", ".op.env", "active_profile", "gateway.json")
    pinned_dirs = ("plugins", "hooks", "profiles", "lib", "patches")

    def assert_pinned(name):
        kind = "directory" if name in pinned_dirs else "file"
        mode = "555" if name in pinned_dirs else "444"
        got = inside(f"stat -c '%U %G %a %F' ${hermesHome}/{name}").strip()
        assert got.startswith(f"root root {mode}") and kind in got, (name, got)
        attrs = inside(f"lsattr -d ${hermesHome}/{name}").split()[0]
        assert "i" in attrs, (name, attrs)

    with subtest("root owns every pinned entry, immutable, in alice's own home"):
        assert inside("stat -c '%U %a' ${hermesHome}").strip() == "alice 700"
        print(inside("ls -la ${hermesHome}"))
        for name in pinned_files + pinned_dirs:
            assert_pinned(name)
        env = as_alice("cat ${hermesHome}/.env")
        assert "OPENAI_API_KEY=sk-locked-test" in env, env
        assert "HERMES_DASHBOARD_OIDC_CLIENT_SECRET=client-secret-alice" in env, env
        inside_fails("runuser -u eve -- cat ${hermesHome}/.env")
        config = json.loads(inside("cat ${hermesHome}/config.yaml"))
        assert config["model"]["default"] == "fake-model", config["model"]

    with subtest("the agent's uid can change none of it"):
        print(as_alice("${pkgs.python3}/bin/python3 ${./attack.py} ${hermesHome} ${workspace} /home/alice"))
        as_alice("mkdir -p /home/alice/.hermes/patches")
        for mod in ("anthropic_billing_bypass", "yaml"):
            as_alice(f"cp ${./evil-patch.py} /home/alice/.hermes/patches/{mod}.py")

    with subtest("after a restart the plants have no effect"):
        restart_agent()
        providers = json.loads(machine.succeed("curl -sf ${origin}/api/auth/providers"))
        assert [p["name"] for p in providers["providers"]] == ["self-hosted"], providers
        status = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "
            "-H 'Origin: ${origin}' "
            "-d '{\"provider\":\"basic\",\"username\":\"evil\",\"password\":\"evil\"}' "
            "${origin}/auth/password-login"
        ).strip()
        assert status == "404", status
        assert machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' ${origin}/api/config"
        ).strip() == "401"
        inside_fails("test -e /home/alice/evil-loaded")
        inside_fails("test -e /home/alice/.hermes/patches/loaded")

    with subtest("the dashboard serves behind its OIDC gate (client secret from secretEnv)"):
        print(machine.succeed(
            "${python}/bin/python3 ${../local-sso/login.py} ${origin} "
            "alice@${domain} alice-password hermes-alice"
        ))

    with subtest("the CLI answers from the locked config, whatever the caller's environment"):
        as_alice("mkdir -p /home/alice/evilpy")
        as_alice("cp ${./evil-sitecustomize.py} /home/alice/evilpy/sitecustomize.py")
        out = as_alice(
            "env HERMES_HOME=/home/alice/.hermes HERMES_MANAGED_DIR=/home/alice/.hermes "
            "PYTHONPATH=/home/alice/evilpy HERMES_ENABLE_PROJECT_PLUGINS=1 "
            "OPENAI_API_KEY=sk-from-the-caller HERMES_BUNDLED_PLUGINS=/home/alice/.hermes/plugins "
            "hermes chat -Q -q 'ping'"
        )
        print(out)
        assert "locked-pong" in out, out
        auth = inside("cat ${llmRecord}")
        assert "Bearer sk-locked-test" in auth and "sk-from-the-caller" not in auth, auth
        inside_fails("test -e /home/alice/evil-loaded")
        inside_fails("test -e /home/alice/.hermes/patches/loaded")

    with subtest("a runtime config change does not persist"):
        before = inside("sha256sum ${hermesHome}/config.yaml")
        machine.execute("nixos-container run hh -- timeout 120 runuser -u alice -- hermes config set display.skin mono")
        assert inside("sha256sum ${hermesHome}/config.yaml") == before

    with subtest("names the agent took before their pins existed are taken back"):
        for name in ("gateway.json", "plugins", "active_profile"):
            inside(f"chattr -i ${hermesHome}/{name}")
            inside(f"rm -rf ${hermesHome}/{name}")
        as_alice("mkdir ${hermesHome}/gateway.json")
        as_alice("touch ${hermesHome}/gateway.json/planted")
        as_alice("sh -c 'printf evil > ${hermesHome}/plugins'")
        as_alice("ln -s /home/alice/.hermes/config.yaml ${hermesHome}/active_profile")
        inside("systemctl restart hermes-locked-alice.service")
        for name in ("gateway.json", "plugins", "active_profile"):
            assert_pinned(name)
        assert inside("cat ${hermesHome}/gateway.json").strip() == "{}"
        machine.wait_until_succeeds(
            "nixos-container run hh -- systemctl is-active hermes-agent-alice.service hermes-dashboard-alice.service"
        )

    # For the reader of the log: what the locked units said about the
    # files they could not write.
    print(inside(
        "journalctl --no-pager -o cat -u hermes-locked-alice -u hermes-agent-alice -u hermes-dashboard-alice"
    ))
  '';
}
