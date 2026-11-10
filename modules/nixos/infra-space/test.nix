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
# both clones (hyperconfig, the secrets repo) fail softly without GitHub.
# The clan vars store, with a bare repo in memberB's guest as GitHub and a
# stub as the real clan-cli (no-op, or committing slowly or in a burst;
# the wrapper itself is the production one): only the `clan` wrapper sets
# CLAN_AGE_STORE_DIR (not a login shell, not the push unit) and hands it
# to clan; it pushes a local commit; an upstream commit to the same file
# makes it fail with the conflicting file and the runbook, no rebase left
# in progress and the local commit intact, and the runbook
# (./hermes-skill/SKILL.md) resolves it; a failed infra-space-secrets-push
# makes it refuse, pointing at the unit's journal, until infra starts the
# unit again; the path unit pushes a commit on its own, and, fired by
# clan's commits mid-run, leaves the store to the run (whose push takes
# them up) instead of failing on clan's half-written store or timing out
# waiting for it; a burst of clan's commits (more starts than systemd's
# default limit) fails neither the push unit nor the path unit, which
# keeps watching. On memberA (som, buildOnHost) the wrapper hands `clan
# machines update` to the stub with `--build-host localhost` unless the
# caller named a build host, and leaves other subcommands, and memberB's,
# as they are. Each member has a software TPM: infra makes its age
# identity on it in the guest and decrypts with it; `tenant` on the host
# can neither read that identity nor, with a copy, use it (no access to
# the TPM); with the ACL stripped, a restart of the container without any
# udev event gives infra its TPM back, as a switch on a booted host must.
# The members run networkd as som and amy do: it keeps off the veth, also
# across a restart. managed also plays a LAN peer routing to a member's
# guest net: refused on sshd and on a host-only guest service the guest's
# firewall opened, which the host itself reaches. afk (./afk.nix) runs as
# infra, `p0-api-key` and `teamclaude-api-key` print the credentials, and
# web_search, fetch and browser stay off even against infra's own
# config.yml.
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
# hermes unit in its guest. memberA also plays som with the dashboard
# (./dashboard.nix): its nginx vhost answers from the host, gated by
# hermes' OIDC login (lazy discovery, so no issuer is needed for that),
# the guest's dashboard port is refused to a LAN peer, and memberB (amy)
# has none. A user on a member (`tenant`) reaches no port of its guest,
# nginx only the dashboard's; root and the sshd forward still do.
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
      # som's and amy's TPM, for infra's age identity
      virtualisation.tpm.enable = true;
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
        # som (memberA) builds every deploy itself; amy (memberB) does not.
        buildOnHost = me == "memberA";
        member = me;
        # the guest's test systems below (machines/ is the fleet's)
        gcRoots = {
          machines = [
            "testbox"
            "testpi"
          ];
          closureMachines = [ "testpi" ];
        };
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
          # the real clan-cli needs the fleet's flake; the wrapper around it
          # is what is tested. The stub records its argv in ~/clan-argv
          # (one line each) and its CLAN_AGE_STORE_DIR in ~/clan-store-dir.
          # `clan slow-commit` writes and commits vars slowly, as `clan vars
          # generate` does, so the push unit fires mid-run, and holds the
          # wrapper's lock (~10 s) longer than the push unit's start
          # timeout, cut to 5 s here (5 min in production, where a `clan
          # machines update` outlasts that). `clan burst` commits 10 times
          # in ~5 s, as `clan vars fix` does (a commit per re-encrypted
          # file).
          (
            { pkgs, lib, ... }:
            {
              systemd.services.infra-space-secrets-push.serviceConfig.TimeoutStartSec = lib.mkForce "5s";
              infraSpace.clanPackage = pkgs.writeShellScriptBin "clan" ''
                set -eu
                printf '%s\n' "$@" > "$HOME/clan-argv"
                printf '%s\n' "''${CLAN_AGE_STORE_DIR-unset}" > "$HOME/clan-store-dir"
                export PATH=${pkgs.git}/bin:$PATH
                case "''${1:-}" in
                  slow-commit)
                    cd "$CLAN_AGE_STORE_DIR"
                    # a commit, then at once the next var's files, uncommitted
                    echo one > slow && git add slow && git commit --quiet -m slow1
                    echo two > slow
                    sleep 5
                    git commit --quiet -am slow2
                    echo three > slow
                    sleep 5
                    git commit --quiet -am slow3
                    ;;
                  burst)
                    cd "$CLAN_AGE_STORE_DIR"
                    for i in $(seq 10); do
                      echo "$i" > burst && git add burst && git commit --quiet -m "burst$i"
                      sleep 0.5
                    done
                    ;;
                esac
              '';
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

      # A later deploy of som (memberA): a change of the guest alone,
      # switched in place, and one of the host's side of the container (an
      # nspawn flag), which restarts it.
      specialisation = lib.mkIf (me == "memberA") {
        guest-change.configuration.hyper.infraSpace.guestModules = [
          { environment.etc."infra-space-guest-change".text = "changed\n"; }
        ];
        host-change.configuration.containers.infra-space.extraFlags = [ "--setenv=INFRA_SPACE_TEST=1" ];
      };

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
        "test-vars/infra-space-secrets-github/id_ed25519" = secret (pkgs.writeText "secrets-github" "not a key\n");
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
    hyper.infraSpace.fleetAccess.keyFile = keys + "/infra-space.pub";
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
          for unit in ["infra-space-clone", "infra-space-clone-secrets"]:
              m.wait_until_succeeds(f"nixos-container run infra-space -- systemctl show -p ActiveState --value {unit}.service | grep -qx inactive", timeout=120)

      with subtest("credentials: 0400 infra on the guest's own /run"):
          for m in members.values():
              for name in ["ssh", "github", "secrets-github"]:
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
              # only the `clan` wrapper sets the store: a clan run
              # otherwise (the devshell's) fails instead of using it unsynced
              assert guest(m, "echo \"''${CLAN_AGE_STORE_DIR-unset}\"").strip() == "unset"
              guest_root(m, "sh -c '! systemctl show -p Environment infra-space-secrets-push.service | grep -q CLAN_AGE_STORE_DIR'")

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

      with subtest("without GitHub the clones give up softly"):
          for m in members.values():
              for unit, checkout in [("infra-space-clone", "hyperconfig"), ("infra-space-clone-secrets", "clan-secrets")]:
                  guest_root(m, f"test ! -e /home/infra/{checkout}")
                  guest_root(m, f"journalctl -u {unit}.service | grep -q 'trying again in 15 min'")
                  guest_root(m, f"systemctl is-active {unit}.timer")

      with subtest("infra's age identity on the host's TPM, out of tenant's reach"):
          identities = "/var/lib/infra-space/home/.config/age/identities"
          host_age = "PATH=${pkgs.age}/bin:${pkgs.age-plugin-tpm}/bin:$PATH"
          for m in members.values():
              guest(m, "mkdir -p ~/.config/age && age-plugin-tpm --generate -o ~/.config/age/identities")
              recipient = guest(m, "age-plugin-tpm -y ~/.config/age/identities").strip()
              out = guest(m, f"set -o pipefail; echo tpm-secret | age -r {recipient} | age -d -i ~/.config/age/identities").strip()
              assert out == "tpm-secret", out
              m.succeed(f"echo tpm-secret | {host_age} age -r {recipient} -o /tmp/secret.age", "chmod 0644 /tmp/secret.age")
              m.fail(f"runuser -u tenant -- cat {identities}")
              m.fail(f"runuser -u tenant -- env {host_age} age -d -i {identities} /tmp/secret.age")
              # a copy is no use without the TPM, which only root and the
              # guest's infra may open
              m.succeed(f"install -m 0644 {identities} /tmp/identities")
              m.fail(f"runuser -u tenant -- env {host_age} age -d -i /tmp/identities /tmp/secret.age")
              assert m.succeed(f"{host_age} age -d -i /tmp/identities /tmp/secret.age").strip() == "tpm-secret"
              m.succeed("rm /tmp/identities /tmp/secret.age")

      with subtest("the clan wrapper keeps the secrets store in sync, failing loudly"):
          m = memberB
          store = "/home/infra/clan-secrets"
          remote = "/home/infra/secrets-remote.git"
          upstream = "/home/infra/upstream"

          def tip(repo):
              return guest(m, f"git -C {repo} rev-parse main").strip()

          def clan_fails():
              rc, out = guest(m, "clan 2>&1", check=False)
              assert rc != 0, out
              return out

          # the timer and the path unit stay out of the wrapper's part
          guest_root(m, "systemctl stop infra-space-secrets-push.path infra-space-secrets-push.timer")
          # GitHub's repo, a second writer's clone of it, and the checkout
          # as infra-space-clone-secrets makes it
          guest(m, f"git init --quiet --bare --initial-branch=main {remote}")
          guest(m, f"git clone --quiet {remote} {upstream} 2>/dev/null; cd {upstream} && echo first > var && git add var && git commit --quiet -m first && git push --quiet origin main")
          guest(m, f"git clone --quiet --branch main {remote} {store} && cd {store} && jj git init --colocate")

          # clan's commit goes up with the run
          guest(m, f"cd {store} && echo local1 > var && git commit --quiet -am local1")
          guest(m, "clan")
          assert tip(remote) == tip(store)
          # the wrapper hands the real clan its store
          assert guest(m, "cat ~/clan-store-dir").strip() == store

          # the same var written upstream and here
          guest(m, f"cd {upstream} && git pull --quiet --ff-only origin main && echo upstream > var && git commit --quiet -am upstream && git push --quiet origin main")
          guest(m, f"cd {store} && echo local2 > var && git commit --quiet -am local2")
          local = tip(store)
          out = clan_fails()
          assert "  var\n" in out and "Secrets store conflict" in out, out
          guest(m, f"cd {store} && test ! -e .git/rebase-merge && test ! -e .git/rebase-apply && test -z \"$(git status --porcelain)\"")
          assert tip(store) == local
          assert guest(m, f"cat {store}/var").strip() == "local2"
          # the runbook: keep upstream's version, `--ours` in a rebase
          guest(m, f"cd {store} && ! git rebase origin/main && git checkout --ours -- var && git add var && GIT_EDITOR=true git rebase --continue")
          assert guest(m, f"cat {store}/var").strip() == "upstream"
          guest(m, "clan")
          assert tip(remote) == tip(store)

          # a failed push unit blocks the wrapper until it succeeds again
          guest(m, f"git -C {store} remote set-url origin /nonexistent")
          m.fail("nixos-container run infra-space -- systemctl start infra-space-secrets-push.service")
          guest_root(m, "systemctl is-failed infra-space-secrets-push.service")
          guest(m, f"git -C {store} remote set-url origin {remote}")
          out = clan_fails()
          assert "infra-space-secrets-push.service failed" in out and "journalctl -u infra-space-secrets-push.service" in out, out
          assert "If it lists conflicting files" in out and "Secrets store conflict" in out, out
          guest(m, "systemctl start infra-space-secrets-push.service")
          guest(m, "clan")

          # a commit made without the wrapper goes up through the path unit
          guest_root(m, "systemctl start infra-space-secrets-push.path infra-space-secrets-push.timer")
          guest(m, f"cd {store} && echo local3 > var && git commit --quiet -am local3")
          m.wait_until_succeeds("nixos-container run infra-space -- runuser -u infra -- bash -lc "
                                + shlex.quote(f"test $(git -C {remote} rev-parse main) = $(git -C {store} rev-parse main)"), timeout=60)

          # the path unit fires on clan's commits mid-run, and leaves the
          # store to the run (whose push takes those commits up) instead of
          # pulling under it or waiting for it past its start timeout
          since = guest_root(m, "date +%s").strip()
          guest(m, "clan slow-commit")
          assert tip(remote) == tip(store)
          m.wait_until_succeeds("nixos-container run infra-space -- sh -c "
                                + shlex.quote("case $(systemctl show -p ActiveState --value infra-space-secrets-push.service) in inactive|failed) ;; *) exit 1;; esac"), timeout=60)
          guest_root(m, "sh -c '! systemctl is-failed --quiet infra-space-secrets-push.service'")
          out = guest_root(m, f"journalctl -o cat -u infra-space-secrets-push.service --since @{since}")
          assert "Starting" in out and "Failed" not in out and "timeout" not in out.lower(), out

          # a burst of clan's commits (more than systemd's default 5 starts
          # in 10 s) leaves neither the push unit nor the path unit failed,
          # and the path unit watching
          since = guest_root(m, "date +%s").strip()
          guest(m, "clan burst")
          assert tip(remote) == tip(store)
          m.wait_until_succeeds("nixos-container run infra-space -- sh -c "
                                + shlex.quote("case $(systemctl show -p ActiveState --value infra-space-secrets-push.service) in inactive|failed) ;; *) exit 1;; esac"), timeout=60)
          units = "infra-space-secrets-push.service infra-space-secrets-push.path"
          rc, out = m.execute(f"nixos-container run infra-space -- systemctl status --no-pager {units} 2>&1")
          print(out)
          guest_root(m, f"sh -c '! systemctl is-failed --quiet {units}'")
          guest_root(m, "systemctl is-active infra-space-secrets-push.path")
          out = guest_root(m, f"journalctl -o cat -u infra-space-secrets-push.service --since @{since}")
          assert out.count("a clan run holds the secrets store") > 5, out
          # still watching: a commit afterwards goes up on its own
          guest(m, f"cd {store} && echo local4 > var && git commit --quiet -am local4")
          m.wait_until_succeeds("nixos-container run infra-space -- runuser -u infra -- bash -lc "
                                + shlex.quote(f"test $(git -C {remote} rev-parse main) = $(git -C {store} rev-parse main)"), timeout=60)

      with subtest("som's clan builds every deploy on its host; amy's leaves clan's default"):
          # memberA's store, as infra-space-clone-secrets makes it from a
          # repo without commits (memberB's is the one above)
          remote = "/home/infra/secrets-remote.git"
          store = "/home/infra/clan-secrets"
          guest(memberA, f"git init --quiet --bare --initial-branch=main {remote} && git clone --quiet {remote} {store} 2>/dev/null && git -C {store} symbolic-ref HEAD refs/heads/main")

          # what the real clan-cli gets from the wrapper
          def argv(m, args):
              guest(m, f"rm -f ~/clan-argv && clan {args}")
              return guest(m, "cat ~/clan-argv").splitlines()

          on_host = ["--build-host", "localhost"]
          assert argv(memberA, "machines update foo") == ["machines", "update", *on_host, "foo"]
          assert argv(memberA, "m u foo bar") == ["m", "u", *on_host, "foo", "bar"]
          assert argv(memberA, "machines update -- foo") == ["machines", "update", *on_host, "--", "foo"]
          # a build host the caller names stays the only one
          assert argv(memberA, "machines update --build-host x foo") == ["machines", "update", "--build-host", "x", "foo"]
          assert argv(memberA, "machines update foo --build-host=x") == ["machines", "update", "foo", "--build-host=x"]
          # other subcommands as they are
          assert argv(memberA, "vars list foo") == ["vars", "list", "foo"]
          assert argv(memberA, "machines build foo") == ["machines", "build", "foo"]
          # amy (option off): nothing added
          assert argv(memberB, "machines update foo") == ["machines", "update", "foo"]

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
          # of the package's bundled skills and ours (Nix's), the allowlist
          # stays enabled, and hermes' essential ones (hermes-agent), which
          # must stay off the raw list too: skill_view checks that one
          skills = json.loads('${builtins.toJSON nodes.memberA.containers.infra-space.config.infraSpace.hermes.skills}')
          allowed = set(skills["allowed"])
          essential = set(skills["essential"])
          assert set(got["skills_essential"]) == essential, got["skills_essential"]
          assert not (essential & set(got["skills_disabled_raw"])), got["skills_disabled_raw"]
          # ours, the Nix skill roots (./hermes.nix nixSkills), are exactly
          # what hermes finds in its external dirs
          ours = set(skills["nix"])
          assert set(got["skills_external"]) == ours, got["skills_external"]
          assert "nixpkgs-bump" in ours, sorted(ours)
          enabled = (set(skills["bundled"]) | ours) - set(got["skills_disabled"])
          assert enabled == allowed | essential, sorted(enabled)
          # hermes' own catalog, so skills the package ships beyond its
          # source's show up too
          rest = set(got["skills_all"]) - set(got["skills_disabled"]) - ours
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

      with subtest("the nightly bump: memberA's timer only; a run without a verdict fails"):
          memberB.fail("nixos-container run infra-space -- systemctl cat nixpkgs-bump.timer")
          memberB.fail("nixos-container run infra-space -- systemctl cat nixpkgs-bump.service")
          guest_root(memberA, "systemctl is-active nixpkgs-bump.timer")
          # 01:30 at Dave's: the zone is part of the calendar, and the
          # guest's tzdata resolves it (01:30 +07 is 18:30 UTC)
          timer = guest_root(memberA, "systemctl show -p TimersCalendar --value nixpkgs-bump.timer")
          assert "01:30:00 Asia/Bangkok" in timer, timer
          cal = guest_root(memberA, "systemd-analyze calendar '*-*-* 01:30:00 Asia/Bangkok'")
          assert "18:30:00 UTC" in cal, cal
          # it follows the gateway without being restarted with it, and a
          # switch does not start it
          deps = guest_root(memberA, "systemctl show -p Wants -p Requires -p After nixpkgs-bump.service")
          assert "Wants=hermes-agent-infra.service" in deps, deps
          assert "Requires=hermes-agent-infra.service" not in deps, deps
          assert "hermes-agent-infra.service" in deps.split("After=")[1], deps
          unit = guest_root(memberA, "systemctl cat nixpkgs-bump.service")
          assert "X-RestartIfChanged=false" in unit, unit
          # the pre-push guard is on infra's PATH (the agent's terminal),
          # and refuses outside a bump workspace (its offline test is the
          # nixpkgs-bump-guard check)
          assert guest(memberA, "command -v nixpkgs-bump-guard").strip() == "/run/current-system/sw/bin/nixpkgs-bump-guard"
          code, out = guest(memberA, "cd /home/infra && nixpkgs-bump-guard 2>&1", check=False)
          assert code != 0 and "not in a bump workspace" in out, (code, out)
          # the verdict is the log's last non-empty line, exactly (hermes
          # -Q's trailing `session_id:` line aside)
          for text, ok in [("x\\nNIXPKGS-BUMP: merged\\n\\nsession_id: 20261110_013000_abc\\n", True),
                           ("NIXPKGS-BUMP: unchanged\\n", True),
                           ("NIXPKGS-BUMP: failed\\nsession_id: x\\n", False),
                           ("NIXPKGS-BUMP: merged\\nmore\\nsession_id: x\\n", False),
                           ("NIXPKGS-BUMP: merged\\nsession_id: x y\\n", False),
                           ("session_id: x\\n", False),
                           ("", False)]:
              code, out = guest(memberA, f"printf '{text}' > /tmp/v && nixpkgs-bump-verdict /tmp/v", check=False)
              assert (code == 0) == ok, (text, code, out)
          guest(memberA, "rm /tmp/v")
          # no checkout (no GitHub here): the condition skips the run
          guest_root(memberA, "systemctl start nixpkgs-bump.service")
          guest_root(memberA, "test ! -d /home/infra/nixpkgs-bump")
          guest(memberA, "mkdir /home/infra/hyperconfig")
          # a second client while one holds the lock starts nothing
          guest(memberA, "mkdir -m 700 /home/infra/nixpkgs-bump && touch /home/infra/nixpkgs-bump/.lock")
          before = int(guest_root(memberA, "cat ${llmRecord} | wc -l").strip())
          code, _ = memberA.execute(
              "nixos-container run infra-space -- "
              "flock /home/infra/nixpkgs-bump/.lock systemctl start nixpkgs-bump.service"
          )
          assert code != 0, code
          journal = guest_root(memberA, "journalctl -u nixpkgs-bump.service")
          assert "another run holds" in journal, journal
          assert int(guest_root(memberA, "cat ${llmRecord} | wc -l").strip()) == before
          guest_root(memberA, "systemctl reset-failed nixpkgs-bump.service")
          # the stub's answer has no verdict as its last line: failed
          # (asked by hand to build cm-pi: the flag file reaches the prompt)
          guest(memberA, "touch /home/infra/nixpkgs-bump/build-cm-pi")
          code, _ = memberA.execute("nixos-container run infra-space -- systemctl start nixpkgs-bump.service")
          assert code != 0, code
          prompt = guest(memberA, "cat /home/infra/nixpkgs-bump/last-prompt")
          assert prompt.rstrip().endswith("CM_PI_BUILD=1"), prompt
          guest(memberA, "test ! -e /home/infra/nixpkgs-bump/build-cm-pi")
          report = guest(memberA, "cat /home/infra/nixpkgs-bump/*.log")
          assert "locked-pong" in report, report
          assert int(guest_root(memberA, "cat ${llmRecord} | wc -l").strip()) > before
          journal = guest_root(memberA, "journalctl -u nixpkgs-bump.service")
          assert "last line: " in journal, journal
          # hermes' own trailing session_id line is never taken for the verdict
          assert "last line: session_id" not in journal, journal
          # umask 077: the report is infra's alone
          assert guest(memberA, "stat -c %a /home/infra/nixpkgs-bump/*.log").split() == ["600"]
          guest(memberA, "rm -r /home/infra/hyperconfig /home/infra/nixpkgs-bump")
          guest_root(memberA, "systemctl reset-failed nixpkgs-bump.service")

      with subtest("the nightly bump's nix: its own cores and jobs, from an untrusted client"):
          busybox = "${pkgs.pkgsStatic.busybox}"
          def cores_of(nix):
              expr = (
                  'derivation { name = "bump-cores"; system = builtins.currentSystem; '
                  f'builder = "''${{builtins.storePath "{busybox}"}}/bin/sh"; nonce = "{nix}"; '
                  'args = [ "-c" "echo $NIX_BUILD_CORES > $out" ]; }'
              )
              out = guest(memberA, f"{nix} build --impure --no-link --print-out-paths --expr {shlex.quote(expr)}").strip()
              return guest(memberA, f"cat {out}").strip()
          assert cores_of("nixpkgs-bump-nix") == "8"  # ./nixpkgs-bump.nix cores (the VM has 2)
          assert cores_of("nix") != "8"
          # honoured without trust: infra is no trusted user of the daemon
          assert "Trusted: 0" in guest(memberA, "nix store info 2>&1"), "infra trusted"
          memberB.fail("nixos-container run infra-space -- which nixpkgs-bump-nix")

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

      with subtest("the guest's TPM access survives a container restart without a udev event"):
          # as on an already booted host after a switch: no device event
          # sets the ACL again, the container's start must
          m = memberB
          uid = "${toString nodes.memberB.containers.infra-space.config.infraSpace.uid}"
          m.succeed(f"getfacl -n /dev/tpmrm0 | grep -q '^user:{uid}:rw'")
          m.succeed(f"setfacl -x u:{uid} /dev/tpmrm0")
          m.fail(f"getfacl -n /dev/tpmrm0 | grep -q '^user:{uid}:'")
          m.succeed("systemctl restart container@infra-space.service")
          m.wait_for_unit("container@infra-space.service")
          m.wait_until_succeeds("nixos-container run infra-space -- systemctl is-active multi-user.target", timeout=120)
          recipient = guest(m, "age-plugin-tpm -y ~/.config/age/identities").strip()
          out = guest(m, f"set -o pipefail; echo tpm-secret | age -r {recipient} | age -d -i ~/.config/age/identities").strip()
          assert out == "tpm-secret", out
          guest(m, "age-plugin-tpm --generate -o /tmp/identities-after-restart")

      with subtest("a change of the guest alone switches it in place; one of the host's side restarts it"):
          m = memberA
          def leader():
              return m.succeed("machinectl show infra-space -p Leader --value").strip()
          def guest_pid(unit):
              return guest_root(m, f"systemctl show -p MainPID --value {unit}").strip()
          def switch(spec):
              return m.succeed(
                  f"/run/booted-system/specialisation/{spec}/bin/switch-to-configuration test 2>&1")
          # a session's long tool command: a process of the guest's own
          # that no unit of the switch owns
          guest_root(m, "systemd-run --unit=session-marker sleep infinity")
          marker = guest_pid("session-marker.service")
          gateway = guest_pid("hermes-agent-infra.service")
          dashboard = guest_pid("hermes-dashboard-infra.service")
          def session_ids():
              # the last column, the id (the rest has relative times)
              return {l.split()[-1] for l in guest(m, "hermes sessions list").splitlines() if l.strip()}
          sessions = session_ids()
          # at least the one `hermes chat` above
          assert len(sessions) > 1, sessions
          before = leader()
          out = switch("guest-change")
          print(out)
          assert "reloading the following units: " in out and "container@infra-space.service" in out.split("reloading the following units: ")[1].splitlines()[0], out
          assert "container@infra-space.service" not in "".join(
              l for l in out.splitlines() if l.startswith(("stopping the following", "restarting the following", "starting the following"))), out
          m.succeed("systemctl is-active container@infra-space.service")
          assert leader() == before, (before, leader())
          assert guest_root(m, "cat /etc/infra-space-guest-change").strip() == "changed"
          system = m.succeed("grep ^SYSTEM_PATH= /etc/nixos-containers/infra-space.conf").strip().split("=", 1)[1]
          assert guest_root(m, "readlink -f /run/current-system").strip() == system, system
          assert guest_pid("session-marker.service") == marker
          assert guest_pid("hermes-agent-infra.service") == gateway
          assert guest_pid("hermes-dashboard-infra.service") == dashboard
          assert session_ids() >= sessions, (sessions, session_ids())
          guest(memberA, "hermes chat -Q -q ping")
          # the host's side of the container: a restart, as before
          out = switch("host-change")
          print(out)
          m.wait_for_unit("container@infra-space.service")
          m.wait_until_succeeds("nixos-container run infra-space -- systemctl is-active multi-user.target", timeout=120)
          assert leader() != before
          m.fail("nixos-container run infra-space -- systemctl is-active session-marker.service")
          guest_root(m, "test ! -e /etc/infra-space-guest-change")
          m.wait_until_succeeds(
              "nixos-container run infra-space -- systemctl is-active hermes-agent-infra.service", timeout=300)
          # the conversation history survives either way
          assert session_ids() >= sessions, (sessions, session_ids())

      with subtest("GC roots on the host for the guest's builds: rooted ones survive a GC, invalid requests are refused"):
          # Last: the GCs below drop whatever earlier subtests left unrooted.
          m = memberA
          roots = "/nix/var/nix/gcroots/infra-space"
          busybox = "${pkgs.pkgsStatic.busybox}"
          # the test builds' builder (additionalPaths, no root of its own)
          m.succeed(f"ln -sfn {busybox} /nix/var/nix/gcroots/test-busybox")
          guest_root(m, "test -S /run/infra-space-gcroots/socket")

          socat = "${pkgs.socat}/bin/socat"

          def sys_expr(machine, n):
              # a system with a build-only input: the toolchain is read at
              # build time, its path not kept in the output
              sh = f'"''${{builtins.storePath "{busybox}"}}/bin/sh"'
              tool = (f'derivation {{ name = "{machine}-toolchain-{n}"; system = builtins.currentSystem; '
                      f'builder = {sh}; args = [ "-c" "echo tool-{n} > $out" ]; }}')
              return (f'(let tool = {tool}; in derivation {{ name = "nixos-system-{machine}-{n}"; '
                      f'system = builtins.currentSystem; builder = {sh}; '
                      f'args = [ "-c" "read t < ''${{tool}}; echo $t system > $out" ]; }} // {{ inherit tool; }})')

          def ev(e):
              return guest(m, f"nix eval --impure --raw --expr {shlex.quote(e)}").strip()

          def build(machine, n, link=None):
              """(system, its .drv, the toolchain's output)"""
              e = sys_expr(machine, n)
              out_link = f"--out-link {link}" if link else "--no-link"
              out = guest(m, f"nix build --impure {out_link} --print-out-paths --expr {shlex.quote(e)}").strip()
              return out, ev(e + ".drvPath"), ev(e + ".tool.outPath")

          def gc():
              m.succeed("nix-collect-garbage >&2")

          def valid(path):
              return m.execute(f"nix-store --check-validity {path}")[0] == 0

          def request(line):
              return guest(m, f"printf '%s\\n' {shlex.quote(line)} | {socat} -t 30 - UNIX-CONNECT:/run/infra-space-gcroots/socket").strip()

          # the problem: the guest's own result link is no root on the host
          v0, _, _ = build("testbox", "0", link="/home/infra/result-testbox-0")
          gc()
          assert not valid(v0), v0
          guest(m, "rm /home/infra/result-testbox-0")

          # a plain machine: current and previous, its runtime closure only
          b1, _, b1tool = build("testbox", "1")
          assert valid(b1tool), b1tool
          out = guest(m, f"infra-space-gcroot testbox {b1}")
          assert out.startswith("ok testbox: current " + b1), out
          b2, b2drv, _ = build("testbox", "2")
          # the .drv form too, and the same system again changes nothing
          for _ in range(2):
              out = guest(m, f"infra-space-gcroot testbox {b2drv}")
              assert f"current {b2}, previous {b1}" in out, out
          b3, _, _ = build("testbox", "3", link="/home/infra/result-testbox-3")
          out = guest(m, "infra-space-gcroot testbox /home/infra/result-testbox-3")
          assert f"current {b3}, previous {b2}" in out, out
          m.succeed(f"test \"$(readlink {roots}/testbox/current)\" = {b3}",
                    f"test \"$(readlink {roots}/testbox/previous)\" = {b2}",
                    f"test ! -e {roots}/testbox/closure")

          # the slow cross machine: plus the whole build closure of current
          p1, p1drv, p1tool = build("testpi", "1")
          out = guest(m, f"infra-space-gcroot testpi {p1}")
          assert "build closure" in out, out
          m.succeed(f"test -L {roots}/testpi/closure/$(basename {p1tool})",
                    f"test -L {roots}/testpi/closure/$(basename {p1drv})")
          # neither the guest nor a host user can touch the roots
          for path in [roots, f"{roots}/testpi", f"{roots}/testpi/closure"]:
              assert m.succeed(f"stat -c '%U %a' {path}").strip() == "root 755", path

          gc()
          for path in [b3, b2, p1, p1tool, p1drv]:
              assert valid(path), path
          # dropped from previous, and build-only paths of a plain machine
          for path in [b1, b1tool]:
              assert not valid(path), path

          # a new testpi: the old closure goes, the old system stays as previous
          p2, _, p2tool = build("testpi", "2")
          guest(m, f"infra-space-gcroot testpi {p2}")
          gc()
          for path in [p2, p2tool, p1]:
              assert valid(path), path
          assert not valid(p1tool), p1tool

          # refused: anything but a built nixos system of a known machine
          unbuilt = ev(sys_expr("testbox", "9") + ".drvPath")
          before = m.succeed(f"find {roots} | sort")
          fake = "/nix/store/" + "a" * 32 + "-nixos-system-testbox-1.drv"
          for line, why in [
              (f"evil {b2drv}", "unknown machine"),
              (f"../testbox {b2drv}", "unknown machine"),
              (f"testpi {b2drv}", "not a nixos system derivation of testpi"),
              (f"testbox {b2}", "not a nixos system derivation"),
              ("testbox /nix/store/../../etc/nixos-system-testbox-1.drv", "not a nixos system derivation"),
              (f"testbox {fake}", "no such derivation"),
              (f"testbox {unbuilt}", "not built"),
              (f"testbox {b2drv} extra", "expected"),
              ("", "expected"),
          ]:
              out = request(line)
              assert out.startswith("refused: ") and why in out, (line, out)
          code, out = guest(m, "infra-space-gcroot testbox " + unbuilt + " 2>&1", check=False)
          assert code != 0 and "not built" in out, out
          assert m.succeed(f"find {roots} | sort") == before
          # only root and the guest's infra may connect
          m.fail(f"runuser -u tenant -- {socat} -t 5 - UNIX-CONNECT:/run/infra-space-gcroots/socket </dev/null")
          # nothing at all: refused too
          out = guest(m, f"{socat} -t 30 - UNIX-CONNECT:/run/infra-space-gcroots/socket </dev/null").strip()
          assert out.startswith("refused: no request"), out
          m.succeed("rm /nix/var/nix/gcroots/test-busybox")
    '';
}
