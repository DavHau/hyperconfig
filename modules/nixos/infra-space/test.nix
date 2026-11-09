# ./default.nix on two members and ./fleet-access.nix on a third machine:
# memberA and memberB stand in for som and amy, each with the container;
# managed is any clan machine, its sshd reading only
# /etc/ssh/authorized_keys.d/%u as vit's does. The mesh is the test VLAN
# (members' addresses: their primary v6, meshInterface eth1), so the path
# is the production one: masqueraded v6 out of one host, the other host's
# socket proxy into its guest. Covered: each container reaches the other
# with `ssh infra-space-<other>` and root on managed (host key by the CA's
# certificate), without a prompt; the credentials sit in
# /run/infra-space/secrets, 0400 infra, on the guest's own /run; `nix
# build` works as infra; the guest sshd answers on the mesh address only;
# the clone fails softly without GitHub. The members run networkd as som
# and amy do: it keeps off the veth, also across a restart. managed also
# plays a LAN peer routing to a member's guest net: refused on sshd and on
# a host-only guest service the guest's firewall opened, which the host
# itself reaches. afk (./afk.nix) runs as infra, `p0-api-key` and
# `teamclaude-api-key` print the credentials, and web_search, fetch and
# browser stay off even against infra's own config.yml.
#
# hermes (./hermes.nix) in memberA's container only (som), with a stub
# model instead of p0: the gateway runs as infra; .env, config.yaml and
# plugins/ are not writable by infra; every platform's toolsets, as
# hermes' own config resolution in its venv computes them in the
# gateway's environment, are exactly the allowlist, and the cli agent's
# tools come from those only; `hermes chat` answers through the stub with
# the p0 credential; the bundled `maps` (core's) stays disabled next to
# the module's list, and of the package's bundled skills and the infra
# skill only the module's allowlist stays enabled (and hermes' essential
# hermes-agent, kept off the raw list as well), in hermes' own
# resolution; skills_list offers none of the others, and skill_view
# serves every skill it offers. memberB (amy) is the plain backup: no
# hermes unit in its guest. memberA also plays som with the dashboard (./dashboard.nix):
# its nginx vhost answers from the host, gated by hermes' OIDC login (lazy
# discovery, so no issuer is needed for that), the guest's dashboard port
# is refused to a LAN peer, and memberB (amy) has none. A user on a member
# (`tenant`) reaches no port of its guest, nginx only the dashboard's; root
# and the sshd forward still do.
#
# ./test-keys is test-only material: infra-space(.pub) the shared
# identity, hostkey-member{A,B}(.pub) the guests' host keys, managed-host
# with managed-host-cert.pub signed by ca.pub (the stand-in for the clan
# sshd CA; its private half was discarded after signing).
{
  pkgs,
  inputs,
}:
let
  inherit (pkgs) lib;
  keys = ./test-keys;
  pub = file: lib.trim (builtins.readFile (keys + "/${file}"));
  sshPort = 2223;
  # the host-only guest service below
  probePort = 8000;
  # the stub model in the guests, for p0 (./hermes.nix)
  llmPort = 9999;
  llmRecord = "/var/lib/fake-llm/auth";
  # the guest's dashboard port for the host's nginx (./dashboard.nix)
  dashboardPort = 9119;
  dashboardHost = "infra-space.test";
  lockedHome = inputs.hyperhermes.lib.lockedHermesHome "infra";
  # the guest's veth addresses (./default.nix)
  guestV4 = "10.235.0.2";
  guestV6 = "fd23:5ace::2";
  memberNames = [
    "memberA"
    "memberB"
  ];

  # What clan provides to ./default.nix: the generator declarations
  # (ignored here) and each file's deployed path.
  clanStub =
    { lib, ... }:
    {
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
                        default = "/etc/test-vars/${generator}/${name}";
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

  secret = source: {
    inherit source;
    mode = "0400";
  };

  member =
    me:
    { nodes, ... }:
    {
      imports = [
        clanStub
        ./default.nix
      ];
      # the container runs hermes' gateway and dashboard
      virtualisation.memorySize = 3072;
      virtualisation.cores = 2;
      # the test build's builder, in the store the daemon serves (no
      # substituters in the sandbox)
      virtualisation.additionalPaths = [ pkgs.pkgsStatic.busybox ];
      # as on som and amy (../encrypted-dns.nix; clan's networkd)
      networking.nftables.enable = true;
      networking.useNetworkd = true;
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.curl
        # for the guest (the store is shared): a query to this host's resolved
        pkgs.dnsutils
      ];
      # a user of the host, as som's agents and tenants
      users.users.tenant.isNormalUser = true;

      hyper.infraSpace = {
        enable = true;
        # som (memberA) runs the agent; amy (memberB) is the plain backup.
        hermes = me == "memberA";
        member = me;
        meshInterface = "eth1";
        members = lib.genAttrs memberNames (m: {
          address = nodes.${m}.networking.primaryIPv6Address;
          inherit sshPort;
          hostKey = pub "hostkey-${m}.pub";
        });
        sshPublicKey = pub "infra-space.pub";
        fleetCertAuthority = {
          publicKey = pub "ca.pub";
          hostNames = [ "managed" ];
        };
        # A later guest service for the host only (som's nginx in front of
        # a dashboard), carelessly opened in the guest's firewall.
        guestModules = [
          (
            { pkgs, ... }:
            {
              systemd.services.host-only-probe = {
                wantedBy = [ "multi-user.target" ];
                serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:${toString probePort},ipv6only=0,reuseaddr,fork EXEC:true";
              };
              networking.firewall.allowedTCPPorts = [ probePort ];
            }
          )
        ]
        # No internet here: p0 is the stub model (the p0 credential still
        # goes along), and the check of the toolsets; where hermes runs.
        ++ lib.optional (me == "memberA") (
          { config, pkgs, ... }:
          {
            services.hyperhermes.settings.providers.p0.base_url = lib.mkForce "http://127.0.0.1:${toString llmPort}/v1";
            # The real model is Anthropic's (no internet here): the stub as p0.
            services.hyperhermes.initialModel = lib.mkForce {
              provider = "custom:p0";
              base_url = "http://127.0.0.1:${toString llmPort}/v1";
              default = "qwen";
            };
            systemd.services.fake-llm = {
              wantedBy = [ "multi-user.target" ];
              before = [ "hermes-agent-infra.service" ];
              serviceConfig = {
                StateDirectory = "fake-llm";
                ExecStart = "${pkgs.python3}/bin/python3 ${inputs.hyperhermes}/checks/locked-config/fake-llm.py ${toString llmPort} ${llmRecord}";
              };
            };
            environment.systemPackages = [
              (pkgs.writeShellScriptBin "infra-space-toolsets" ''
                exec ${config.services.hyperhermes.package.hermesVenv}/bin/python3 ${./test-toolsets.py}
              '')
            ];
          }
        );
      };
      # what ../inference-api-key.nix and ../teamclaude-api-key.nix declare on som and amy
      clan.core.vars.generators.inference-api-key.files.token = { };
      clan.core.vars.generators.teamclaude-api-key.files.key = { };

      # memberA is som: the dashboard behind its nginx (plain HTTP here).
      hyper.infraSpace.dashboard = lib.mkIf (me == "memberA") {
        enable = true;
        host = dashboardHost;
        url = "http://${dashboardHost}";
        # never contacted: hermes discovers its issuer at the first sign-in
        issuer = "https://id.test";
        clientSecretFile = "/etc/test-vars/oidc/secret";
      };

      environment.etc = {
        "test-vars/infra-space-ssh/id_ed25519" = secret (keys + "/infra-space");
        "test-vars/infra-space-github/id_ed25519" = secret (pkgs.writeText "github" "not a key\n");
        "test-vars/infra-space-age/key.txt" = secret (pkgs.writeText "age" "not a key\n");
        "test-vars/infra-space-hostkey/ssh_host_ed25519_key" = secret (keys + "/hostkey-${me}");
        "test-vars/inference-api-key/token" = secret (pkgs.writeText "p0-token" "test-p0-token\n");
        "test-vars/teamclaude-api-key/key" = secret (pkgs.writeText "teamclaude-key" "sk-ant-oat01-test\n");
        "test-vars/oidc/secret" = secret (pkgs.writeText "oidc" "test-client-secret\n");
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "infra-space";
  globalTimeout = 1800;
  node.specialArgs = { inherit inputs; };

  nodes.memberA = member "memberA";
  nodes.memberB = member "memberB";

  nodes.managed = {
    imports = [ ./fleet-access.nix ];
    hyper.infraSpace.fleetAccess.publicKey = pub "infra-space.pub";
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          type = "ed25519";
          path = "/etc/ssh/test_host_ed25519_key";
        }
      ];
      settings.HostCertificate = "${keys}/managed-host-cert.pub";
      # as on vit (machines/vit/configuration.nix)
      authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    };
    environment.etc."ssh/test_host_ed25519_key" = {
      source = keys + "/managed-host";
      mode = "0600";
    };
    environment.systemPackages = [ pkgs.netcat-openbsd ];
  };

  testScript =
    { nodes, ... }:
    ''
      import shlex

      def guest(m, cmd, check=True):
          full = "nixos-container run infra-space -- runuser -u infra -- bash -lc " + shlex.quote(cmd)
          return m.succeed(full) if check else m.execute(full)

      def guest_root(m, cmd):
          return m.succeed("nixos-container run infra-space -- " + cmd)

      members = {"memberA": memberA, "memberB": memberB}

      def reach_each_other():
          for me, m in members.items():
              for other in members:
                  if other == me:
                      continue
                  out = guest(m, f"ssh -o BatchMode=yes infra-space-{other} 'id -un'")
                  assert out.strip() == "infra", out

      start_all()
      managed.wait_for_unit("sshd.service")
      for m in members.values():
          m.wait_for_unit("container@infra-space.service")
          m.wait_until_succeeds("nixos-container run infra-space -- systemctl is-active sshd.service infra-space-secrets.service", timeout=120)
          m.wait_until_succeeds("nixos-container run infra-space -- systemctl show -p ActiveState --value infra-space-clone.service | grep -qx inactive", timeout=120)

      with subtest("credentials: 0400 infra on the guest's own /run"):
          for m in members.values():
              for name in ["ssh", "github", "sops-age"]:
                  out = guest_root(m, f"stat -c '%a %U %G' /run/infra-space/secrets/{name}").strip()
                  assert out == "400 infra infra", (name, out)
              out = guest_root(m, "findmnt -n -o TARGET,FSTYPE -T /run/infra-space/secrets/ssh").split()
              assert out == ["/run", "tmpfs"], out
              # the guest's own tmpfs, not a host path bound in
              src = guest_root(m, "findmnt -n -o SOURCE -T /run/infra-space/secrets/ssh").strip()
              assert "[" not in src, src
              # the ssh host key is sshd's alone
              guest_root(m, "test ! -e /run/infra-space/secrets/ssh-host-key")
              out = guest_root(m, "stat -c '%a %U' /run/infra-space/ssh_host_ed25519_key").strip()
              assert out == "600 root", out
              assert guest(m, "echo $SOPS_AGE_KEY_FILE").strip() == "/run/infra-space/secrets/sops-age"

      with subtest("the members reach each other's container"):
          reach_each_other()

      with subtest("networkd keeps off the container's veth, also across its restart"):
          for m in members.values():
              m.succeed("networkctl status ve-infra-space | grep -E 'State: .*unmanaged'")
              # only the containers module's addresses (and the kernel's
              # v6 link-local): no networkd /28 or 169.254 the forward
              # could take as its source
              addrs = sorted(a for a in m.succeed("ip -o addr show dev ve-infra-space | awk '{print $4}'").split() if not a.startswith("fe80:"))
              assert addrs == ["10.235.0.1/32", "fd23:5ace::1/128"], addrs
              m.succeed("systemctl restart systemd-networkd.service")
              m.wait_for_unit("systemd-networkd.service")
              m.succeed("ip route get ${guestV4} | grep -q 'dev ve-infra-space src 10.235.0.1'")
              m.succeed("ip -6 route get ${guestV6} | grep 'dev ve-infra-space' | grep -q 'src fd23:5ace::1'")
          reach_each_other()

      with subtest("each container is root on the managed machine"):
          for m in members.values():
              out = guest(m, "ssh -o BatchMode=yes root@managed 'id -un'")
              assert out.strip() == "root", out

      with subtest("the guest sshd answers on the mesh address only"):
          for name in members:
              node = members[name]
              v6 = {"memberA": "${nodes.memberA.networking.primaryIPv6Address}", "memberB": "${nodes.memberB.networking.primaryIPv6Address}"}[name]
              v4 = {"memberA": "${nodes.memberA.networking.primaryIPAddress}", "memberB": "${nodes.memberB.networking.primaryIPAddress}"}[name]
              managed.succeed(f"nc -z -w 5 {v6} ${toString sshPort}")
              managed.fail(f"nc -z -w 5 {v4} ${toString sshPort}")

      with subtest("the guest admits its host only, not a LAN peer routing to it"):
          for name, node in members.items():
              node.wait_until_succeeds("nc -z -w 5 ${guestV4} ${toString probePort}", timeout=60)
              node.succeed("nc -z -w 5 ${guestV6} ${toString probePort}")
              v6 = {"memberA": "${nodes.memberA.networking.primaryIPv6Address}", "memberB": "${nodes.memberB.networking.primaryIPv6Address}"}[name]
              v4 = {"memberA": "${nodes.memberA.networking.primaryIPAddress}", "memberB": "${nodes.memberB.networking.primaryIPAddress}"}[name]
              # managed stands in for a peer on amy's wifi or som's LAN
              managed.succeed(f"ip route add ${guestV4}/32 via {v4}")
              managed.succeed(f"ip -6 route add ${guestV6}/128 via {v6}")
              for port in [22, ${toString probePort}]:
                  managed.fail(f"nc -z -w 5 ${guestV4} {port}")
                  managed.fail(f"nc -z -w 5 ${guestV6} {port}")
              managed.succeed("ip route del ${guestV4}/32", "ip -6 route del ${guestV6}/128")

      with subtest("nix build works as infra"):
          busybox = "${pkgs.pkgsStatic.busybox}"
          expr = (
              'derivation { name = "infra-space-test"; system = builtins.currentSystem; '
              f'builder = "''${{builtins.storePath "{busybox}"}}/bin/sh"; '
              'args = [ "-c" "echo built > $out" ]; }'
          )
          for m in members.values():
              out = guest(m, f"nix build --impure --no-link --print-out-paths --expr {shlex.quote(expr)}").strip()
              assert guest(m, f"cat {out}").strip() == "built", out

      with subtest("without GitHub the clone gives up softly"):
          for m in members.values():
              guest_root(m, "test ! -e /home/infra/hyperconfig")
              guest_root(m, "journalctl -u infra-space-clone.service | grep -q 'trying again in 15 min'")
              guest_root(m, "systemctl is-active infra-space-clone.timer")

      with subtest("afk as infra: runs, finds its keys, no web tools"):
          import json

          # From $HOME, as after an ssh login: omp reads project settings
          # from the cwd, and runuser keeps root's.
          def afk_setting(m, key):
              out = guest(m, f"cd ~ && afk config get {key} --json")
              return json.loads(out[out.index("{"):])["value"]

          pinned = ["web_search.enabled", "fetch.enabled", "browser.enabled"]
          for m in members.values():
              guest(m, "cd ~ && afk --version")
              # models.yml routes anthropic through TeamClaude, keys by command
              models = guest(m, "cat ~/.omp/profiles/afk/agent/models.yml")
              assert '"!teamclaude-api-key"' in models and '"!p0-api-key"' in models, models
              assert guest(m, "p0-api-key").strip() == "test-p0-token"
              assert guest(m, "teamclaude-api-key").strip() == "sk-ant-oat01-test"
              for key in pinned:
                  assert afk_setting(m, key) is False, key
              # an unpinned distro default still comes through
              assert afk_setting(m, "startup.quiet") is True
              # the user's (or the agent's) config.yml cannot switch them back on
              guest(m, "printf 'web_search:\\n  enabled: true\\nfetch:\\n  enabled: true\\nbrowser:\\n  enabled: true\\n' > ~/.omp/profiles/afk/agent/config.yml")
              for key in pinned:
                  assert afk_setting(m, key) is False, key
              guest(m, "rm ~/.omp/profiles/afk/agent/config.yml")
              # no personal skills: nothing links ~/.agents/skills
              guest(m, "test ! -e ~/.agents/skills")
              guest(m, "tmux -V")
      allowlist = ["delegation", "file", "skills", "terminal", "todo"]
      # what the five toolsets hold, and hermes' tool search over them
      allowed_tools = {"delegate_task", "patch", "process_manage", "read_file", "search_files", "skill_manage",
                       "skill_view", "skills_list", "terminal", "todo_list", "write_file", "tool_call",
                       "tool_describe", "tool_search"}

      with subtest("hermes runs as infra on memberA, its configuration out of infra's reach; none on memberB"):
          memberB.fail("nixos-container run infra-space -- systemctl cat hermes-agent-infra.service")
          m = memberA
          m.wait_until_succeeds(
              "nixos-container run infra-space -- systemctl is-active hermes-locked-infra.service "
              "hermes-agent-infra.service hermes-dashboard-infra.service", timeout=300)
          pid = guest_root(m, "systemctl show -p MainPID --value hermes-agent-infra.service").strip()
          assert guest_root(m, f"stat -c %U /proc/{pid}").strip() == "infra", pid
          # hardened (core's hardening.nix), in the container too
          status = guest_root(m, f"cat /proc/{pid}/status")
          assert "NoNewPrivs:\t1" in status and "Seccomp:\t2" in status, status
          # the keys, from the host's credentials into root's .env
          env = guest_root(m, "cat ${lockedHome}/.env")
          assert "P0_API_KEY=test-p0-token" in env, env
          assert "ANTHROPIC_TOKEN=sk-ant-oat01-test" in env, env
          assert "ANTHROPIC_BASE_URL=https://teamclaude.davhau.com" in env, env
          assert "HERMES_DASHBOARD_OIDC_CLIENT_SECRET=test-client-secret" in env, env
          for name in [".env", "config.yaml"]:
              guest(m, f"test ! -w ${lockedHome}/{name}")
              guest(m, f"! (echo X=1 >> ${lockedHome}/{name}) 2>/dev/null")
              guest(m, f"! rm -f ${lockedHome}/{name} 2>/dev/null")
          guest(m, "test ! -w ${lockedHome}/plugins")
          guest(m, "! touch ${lockedHome}/plugins/planted 2>/dev/null")
          guest(m, "! mv ${lockedHome}/plugins ${lockedHome}/plugins.old 2>/dev/null")
          guest_root(m, "test -d ${lockedHome}/plugins -a ! -e ${lockedHome}/plugins/planted")

      with subtest("hermes' own resolution gives exactly the allowlist, on every platform"):
          import json
          check = (
              "pid=$(systemctl show -p MainPID --value hermes-agent-infra.service); "
              "mapfile -d ''' < /proc/$pid/environ envs; "
              'exec runuser -u infra -- env -i "''${envs[@]}" /run/current-system/sw/bin/infra-space-toolsets'
          )
          got = json.loads(guest_root(memberA, "bash -c " + shlex.quote(check)).strip().splitlines()[-1])
          print(json.dumps(got))
          for platform, toolsets in got["platforms"].items():
              assert toolsets == allowlist, (platform, toolsets)
          assert set(got["tools"]) <= allowed_tools, got["tools"]
          assert "terminal" in got["tools"], got["tools"]
          assert got["checkpoints"] is False, got
          # core's `maps` (web fetching) next to the module's list
          assert {"maps", "apple-notes", "xurl"} <= set(got["skills_disabled"]), got["skills_disabled"]
          assert "systematic-debugging" not in got["skills_disabled"], got["skills_disabled"]
          # of the package's bundled skills and the infra skill, the allowlist
          # stays enabled, and hermes' essential ones (hermes-agent), which
          # must stay off the raw list too: skill_view checks that one
          skills = json.loads('${builtins.toJSON nodes.memberA.containers.infra-space.config.infraSpace.hermes.skills}')
          allowed = set(skills["allowed"])
          essential = set(skills["essential"])
          assert set(got["skills_essential"]) == essential, got["skills_essential"]
          assert not (essential & set(got["skills_disabled_raw"])), got["skills_disabled_raw"]
          enabled = (set(skills["bundled"]) | {"infra-space"}) - set(got["skills_disabled"])
          assert enabled == allowed | essential, sorted(enabled)
          # hermes' own catalog, so skills the package ships beyond its
          # source's show up too
          rest = set(got["skills_all"]) - set(got["skills_disabled"]) - {"infra-space"}
          assert rest <= allowed | essential, sorted(rest)
          # skills_list offers the allowlist, none of the others, and
          # skill_view serves every one it offers
          assert allowed | essential <= set(got["skills_listed"]), got["skills_listed"]
          assert not (set(got["skills_listed"]) & (set(skills["bundled"]) - allowed - essential)), got["skills_listed"]
          assert got["skills_viewable"] == got["skills_listed"], (got["skills_listed"], got["skills_viewable"])

      with subtest("hermes answers through p0's credential"):
          out = guest(memberA, "hermes chat -Q -q ping")
          assert "locked-pong" in out, out
          assert "Bearer test-p0-token" in guest_root(memberA, "cat ${llmRecord}")

      with subtest("the dashboard: som's nginx from the host, refused to a LAN peer, none on amy"):
          origin = "--resolve ${dashboardHost}:80:127.0.0.1 http://${dashboardHost}"
          memberA.wait_until_succeeds(f"curl -sf {origin}/api/status", timeout=180)
          providers = json.loads(memberA.succeed(f"curl -sf {origin}/api/auth/providers"))
          assert [p["name"] for p in providers["providers"]] == ["self-hosted"], providers
          # gated: no session, no config
          code = memberA.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {origin}/api/config").strip()
          assert code == "401", code
          memberA.succeed("nc -z -w 5 ${guestV4} ${toString dashboardPort}")
          managed.succeed("ip route add ${guestV4}/32 via ${nodes.memberA.networking.primaryIPAddress}")
          managed.fail("nc -z -w 5 ${guestV4} ${toString dashboardPort}")
          managed.succeed("ip route del ${guestV4}/32")
          memberB.fail("nixos-container run infra-space -- systemctl cat infra-space-dashboard.socket")
          memberB.fail("nc -z -w 5 ${guestV4} ${toString dashboardPort}")

      with subtest("on the host only root and the forwarders reach the guest"):
          for m in members.values():
              for addr in ["${guestV4}", "${guestV6}"]:
                  for port in [22, ${toString probePort}, ${toString dashboardPort}]:
                      m.fail(f"runuser -u tenant -- nc -z -w 5 {addr} {port}")
                  m.succeed(f"nc -z -w 5 {addr} 22", f"nc -z -w 5 {addr} ${toString probePort}")
          # nginx: the dashboard port only (on v4, where the guest serves it)
          memberA.succeed("runuser -u nginx -- nc -z -w 5 ${guestV4} ${toString dashboardPort}")
          for addr in ["${guestV4}", "${guestV6}"]:
              for port in [22, ${toString probePort}]:
                  memberA.fail(f"runuser -u nginx -- nc -z -w 5 {addr} {port}")
          memberA.succeed(f"curl -sf {origin}/api/status")
          # the sshd forward (its own uid), and the replies of this host's
          # resolved to the guest
          reach_each_other()
          for m in members.values():
              out = guest_root(m, "${pkgs.dnsutils}/bin/dig +short +time=5 +tries=1 @10.235.0.1 managed").strip()
              assert out, out
    '';
}
