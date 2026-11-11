# The named spaces (./default.nix) on one host beside infra-space, and
# Dave's side of them (./client.nix) on the same host (the test keeps both on one host).
# `host` stands in for som (the spaces, infra-space, networkd, nftables,
# its TPM), `peer` for everything else: a LAN neighbour (its v4,
# 192.168.1.0/24, private) and a machine on the internet (its v6, the
# test VLAN's 2001:db8:1::/64, global) at once. Covered:
#
#   - the space (geninf-space) starts, with sshd at [host's mesh
#     address]:<sshPort> only (2224): `peer` logs in with Dave's key and the host key it
#     pinned (the space's host key credential); not on the host's v4, not
#     by routing to the guest's veth address through the host;
#   - isolation: from each space, neither the other space, infra-space
#     (their veth addresses, their ssh ports on the mesh address), the
#     host's own sshd nor the LAN (peer's v4) are reachable; the internet
#     (peer's v6) and DNS on its host are; a user of the host reaches no
#     port of a space;
#   - credentials: each space has exactly its own in /run/<name>/secrets
#     (0400 the user, the guest's own tmpfs), none of infra-space's keys
#     anywhere in its file system, the TPM bound in, AGE_KEYFILE the
#     main root key;
#   - the clones of its org's repositories fail softly without the forges;
#   - herdr: Dave's user activation saves the spaces as herdr machines
#     (`herdr machine list`, targets the ssh aliases `space-<name>`); the
#     bridge herdr runs over ssh at attach starts each guest's herdr
#     server, and `herdr machine status` then finds them ok; an entry of a
#     space no longer declared (retired) is removed, Dave's own kept;
#   - infra-space beside them still starts and admits its own ssh port;
#   - deploys (specialisations, `switch-to-configuration test`): a change
#     of the guests alone reloads each container (the guest's own switch
#     inside), its leader, a user's process outside any unit, Dave's tmux
#     session and its child and the herdr server all kept, the guest's
#     /run/current-system the new system; one of the host's side
#     (geninf-space's nspawn flags) restarts it into the new guest, also while
#     clients keep connecting to the ssh forwards during the switch.
#
# ./test-keys is test-only material: admin(.pub) stands in for Dave's key,
# hostkey-<space>(.pub) for the spaces' host keys; infra-space's are its
# test's (../infra-space/test-keys).
{
  pkgs,
  inputs,
}:
let
  inherit (pkgs) lib;
  keys = ./test-keys;
  isKeys = ../infra-space/test-keys;
  pub = file: lib.trim (builtins.readFile (keys + "/${file}"));
  registry = import ./registry.nix;
  spaceNames = lib.attrNames registry;
  # the guests' veth addresses (./default.nix)
  guestV4 = name: "10.235.0.${toString (4 * registry.${name}.index + 2)}";
  hostV4 = name: "10.235.0.${toString (4 * registry.${name}.index + 1)}";
  peerPort = 8080;

  clanStub =
    { lib, ... }:
    {
      options.clan.core.settings = {
        machine.name = lib.mkOption {
          type = lib.types.str;
          # the machine ./registry.nix puts the spaces on
          default = "som";
        };
        directory = lib.mkOption {
          type = lib.types.str;
          default = "/nonexistent";
        };
      };
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
  fake = name: secret (pkgs.writeText name "test ${name}\n");
in
pkgs.testers.runNixOSTest {
  name = "spaces";
  globalTimeout = 1800;
  node.specialArgs = { inherit inputs; };

  nodes.host =
    { nodes, ... }:
    let
      address = nodes.host.networking.primaryIPv6Address;
    in
    {
      imports = [
        clanStub
        ../infra-space
        ./default.nix
        ./client.nix
        # herdr for Dave, as on amy (../dave.nix)
        ../herdr-jj.nix
      ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
      virtualisation.tpm.enable = true;
      networking.nftables.enable = true;
      networking.useNetworkd = true;
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.dnsutils
      ];
      users.users.tenant.isNormalUser = true;

      # amy's infra-space, the plain member (no hermes, no dashboard)
      hyper.infraSpace = {
        enable = true;
        member = "host";
        meshInterface = "eth1";
        members.host = {
          inherit address;
          sshPort = 2223;
          hostKey = lib.trim (builtins.readFile (isKeys + "/hostkey-memberA.pub"));
        };
        sshPublicKey = lib.trim (builtins.readFile (isKeys + "/infra-space.pub"));
        fleetCertAuthority = {
          publicKey = lib.trim (builtins.readFile (isKeys + "/ca.pub"));
          hostNames = [ "peer" ];
        };
      };

      hyper.spaces = lib.genAttrs spaceNames (_: {
        enable = true;
        inherit address;
        meshInterface = "eth1";
        adminKeys.dave = pub "admin.pub";
      });

      # Dave on amy: his herdr gets the spaces as machines.
      users.users.dave = {
        isNormalUser = true;
        linger = true;
      };
      hyper.spacesClient = {
        herdrUser = "dave";
        spaces = lib.mapAttrs (name: r: {
          inherit (r) machine sshPort;
          user = name;
          inherit address;
          hostKey = pub "hostkey-${name}.pub";
        }) registry;
      };

      # A later deploy: a change of the guests alone (every space and
      # infra-space), switched in place, and one of geninf-space's host side
      # (an nspawn flag), which restarts it.
      specialisation = {
        guest-change.configuration = {
          hyper.infraSpace.guestModules = [ { environment.etc."guest-change".text = "changed\n"; } ];
          hyper.spaces = lib.genAttrs spaceNames (_: {
            guestModules = [
              (
                { pkgs, ... }:
                {
                  environment.etc."guest-change".text = "changed\n";
                  environment.systemPackages = [ pkgs.hello ];
                }
              )
            ];
          });
        };
        host-change.configuration.containers.geninf-space.extraFlags = [ "--setenv=SPACE_TEST=1" ];
      };

      clan.core.vars.generators.inference-api-key.files.token = { };
      clan.core.vars.generators.teamclaude-api-key.files.key = { };
      environment.etc = {
        "test-vars/infra-space-ssh/id_ed25519" = secret (isKeys + "/infra-space");
        "test-vars/infra-space-github/id_ed25519" = fake "infra-space-github";
        "test-vars/infra-space-secrets-github/id_ed25519" = fake "infra-space-secrets-github";
        "test-vars/infra-space-hostkey/ssh_host_ed25519_key" = secret (isKeys + "/hostkey-memberA");
        "test-vars/inference-api-key/token" = fake "p0-token";
        "test-vars/teamclaude-api-key/key" = fake "teamclaude-key";
        "test-vars/space-geninf-space-hostkey/ssh_host_ed25519_key" = secret (keys + "/hostkey-geninf-space");
        "test-vars/space-geninf-space-root-ssh/id_ed25519" = fake "geninf-space-root-ssh";
        "test-vars/space-geninf-space-root-ssh-agave/id_ed25519" = fake "geninf-space-root-ssh-agave";
        "test-vars/space-geninf-space-git-geninf/id_ed25519" = fake "geninf-space-git-geninf";
        "test-vars/space-geninf-space-git-clan-lol/id_ed25519" = fake "geninf-space-git-clan-lol";
        "test-vars/space-geninf-space-token-geninf/token" = fake "geninf-space-token-geninf";
        "test-vars/space-geninf-space-token-clan-lol/token" = fake "geninf-space-token-clan-lol";
        "dave-ssh/id_ed25519" = {
          source = keys + "/admin";
          mode = "0400";
          user = "dave";
        };
      };
    };

  nodes.peer = {
    environment.systemPackages = [ pkgs.netcat-openbsd ];
    systemd.services.listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:${toString peerPort},ipv6only=0,reuseaddr,fork EXEC:true";
    };
    networking.firewall.allowedTCPPorts = [ peerPort ];
  };

  testScript =
    { nodes, ... }:
    let
      hostV6 = nodes.host.networking.primaryIPv6Address;
      hostIp4 = nodes.host.networking.primaryIPAddress;
      peerV6 = nodes.peer.networking.primaryIPv6Address;
      peerV4 = nodes.peer.networking.primaryIPAddress;
      nc = "${pkgs.netcat-openbsd}/bin/nc";
      spaces = lib.mapAttrs (name: r: {
        port = r.sshPort;
        v4 = guestV4 name;
        hostV4 = hostV4 name;
        hostKey = pub "hostkey-${name}.pub";
      }) registry;
    in
    ''
      import json, re, shlex

      spaces = json.loads('${builtins.toJSON spaces}')
      expected_creds = {
          "geninf-space": {"p0-api-key", "teamclaude-api-key", "root-ssh", "root-ssh-agave", "git-geninf", "git-clan-lol", "token-geninf", "token-clan-lol"},
      }
      # tea's logins: forge -> (bot user, token credential, default)
      expected_forges = {
          "geninf-space": {
              "git.geninf.io": ("davhau-gi-bot", "token-geninf", True),
              "git.clan.lol": ("davhau-clan-bot", "token-clan-lol", False),
          },
      }

      def in_space(name, cmd, check=True):
          full = f"nixos-container run {name} -- runuser -u {name} -- bash -lc " + shlex.quote(cmd)
          return host.succeed(full) if check else host.execute(full)

      def space_root(name, cmd):
          return host.succeed(f"nixos-container run {name} -- " + cmd)

      def space_fails(name, cmd):
          host.fail(f"nixos-container run {name} -- runuser -u {name} -- " + cmd)

      start_all()
      peer.wait_for_unit("listener.service")
      for name in ["infra-space", *spaces]:
          host.wait_for_unit(f"container@{name}.service")
      for name in spaces:
          host.wait_until_succeeds(f"nixos-container run {name} -- systemctl is-active sshd.service {name}-secrets.service", timeout=120)

      peer.succeed("install -d -m 0700 /root/.ssh && install -m 0400 ${keys}/admin /root/.ssh/id_ed25519")
      with subtest("sshd on the mesh address only, with its pinned host key"):
          for name, s in spaces.items():
              port = s["port"]
              peer.succeed(f"echo '[${hostV6}]:{port} {s['hostKey']}' >> /root/.ssh/known_hosts")
              peer.wait_until_succeeds(f"nc -z -w 5 ${hostV6} {port}", timeout=60)
              out = peer.succeed(f"timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -p {port} {name}@${hostV6} id -un").strip()
              assert out == name, out
              peer.fail(f"nc -z -w 5 ${hostIp4} {port}")
              # a LAN peer routing to the guest's veth address
              peer.succeed(f"ip route add {s['v4']}/32 via ${hostIp4}")
              peer.fail(f"nc -z -w 5 {s['v4']} 22")
              peer.succeed(f"ip route del {s['v4']}/32")
              # nor a user of the host
              host.fail(f"runuser -u tenant -- nc -z -w 5 {s['v4']} 22")
              host.succeed(f"nc -z -w 5 {s['v4']} 22")
          # infra-space beside them, unchanged
          peer.succeed("nc -z -w 5 ${hostV6} 2223")

      with subtest("each space: the internet and its DNS, nothing else"):
          for name, s in spaces.items():
              # the internet stand-in (global v6)
              in_space(name, "${nc} -z -w 5 ${peerV6} ${toString peerPort}")
              # the LAN (private v4)
              space_fails(name, "${nc} -z -w 5 ${peerV4} ${toString peerPort}")
              # DNS from its host's resolved
              out = space_root(name, f"${pkgs.dnsutils}/bin/dig +short +time=5 +tries=1 @{s['hostV4']} peer").strip()
              assert out, out
              # its host: no sshd, no other space's or infra-space's forward
              for port in [22, 2223, *(o["port"] for o in spaces.values())]:
                  space_fails(name, f"${nc} -z -w 5 {s['hostV4']} {port}")
                  space_fails(name, f"${nc} -z -w 5 ${hostV6} {port}")
              # infra-space and the other spaces on their veths
              for target in ["10.235.0.2", *(o["v4"] for o in spaces.values() if o is not s)]:
                  space_fails(name, f"${nc} -z -w 5 {target} 22")

      with subtest("credentials: its own, none of infra-space's"):
          is_key = "${lib.elemAt (lib.splitString "\n" (builtins.readFile (isKeys + "/infra-space"))) 2}"
          for name in spaces:
              got = set(space_root(name, f"ls /run/{name}/secrets").split())
              assert got == expected_creds[name], (name, got)
              for cred in got:
                  out = space_root(name, f"stat -c '%a %U' /run/{name}/secrets/{cred}").strip()
                  assert out == f"400 {name}", (cred, out)
              out = space_root(name, f"findmnt -n -o TARGET,FSTYPE -T /run/{name}/secrets/git-geninf").split()
              assert out == ["/run", "tmpfs"], out
              space_root(name, f"test ! -e /run/{name}/secrets/ssh-host-key")
              space_root(name, "test ! -e /run/infra-space")
              # `[c]...`: the pattern never matches the command line itself,
              # which `nixos-container run` leaves in a transient unit in /run
              needle = "[" + is_key[0] + "]" + re.escape(is_key[1:])
              rc, hits = host.execute(f"nixos-container run {name} -- grep -rlsE {shlex.quote(needle)} /run /etc /home /var /root")
              assert rc == 1, (name, hits)
              # no fleet names
              space_root(name, "sh -c '! grep -q \"\\.d$\" /etc/hosts'")
          in_space("geninf-space", "test -r /dev/tpmrm0 -a -w /dev/tpmrm0")
          # the clans' vars: clan's age store takes the main root-ssh key
          assert in_space("geninf-space", "echo $AGE_KEYFILE").strip() == "/run/geninf-space/secrets/root-ssh"
          in_space("geninf-space", "test -r $AGE_KEYFILE")
          # agave-infra's hosts: its admin key first, then the main one
          out = in_space("geninf-space", "ssh -G 2.31.31.53 | grep -i ^identityfile")
          assert out.split() == ["identityfile", "/run/geninf-space/secrets/root-ssh-agave", "identityfile", "/run/geninf-space/secrets/root-ssh"], out
          out = in_space("geninf-space", "ssh -G 192.0.2.1 | grep -i ^identityfile")
          assert out.split() == ["identityfile", "/run/geninf-space/secrets/root-ssh"], out

      with subtest("tea: a login per forge, its token from the credential, on tmpfs only"):
          for name, forges in expected_forges.items():
              host.wait_until_succeeds(f"nixos-container run {name} -- systemctl is-active {name}-forge-cli.service", timeout=60)
              conf = f"/run/{name}/tea/tea/config.yml"
              out = space_root(name, f"stat -c '%a %U' {conf}").strip()
              assert out == f"600 {name}", out
              out = space_root(name, f"findmnt -n -o TARGET,FSTYPE -T {conf}").split()
              assert out == ["/run", "tmpfs"], out
              # what the agent sees, without the network
              rows = in_space(name, "tea logins list -o tsv").strip().splitlines()
              print(rows)
              got = {r.split("\t")[0]: r.split("\t") for r in rows[1:]}
              assert set(got) == set(forges), got
              tokens = {l["name"]: l.get("token") for l in json.loads(in_space(name, f"cat {conf}"))["logins"]}
              for host_, (user, cred, default) in forges.items():
                  _, url, ssh_host, u, d = got[host_]
                  assert (url, ssh_host, u, d) == (f"https://{host_}", host_, user, str(default).lower()), got[host_]
                  # the fake var's content (`fake` above), newline trimmed
                  assert tokens[host_] == f"test {name}-{cred}", host_
              # a checkout's ssh remote picks its forge's login (the request
              # then fails, no network; the error names the URL)
              for host_ in forges:
                  out = in_space(name, f"cd $(mktemp -d) && git init -q && git remote add origin gitea@{host_}:org/repo.git && timeout 60 tea pr ls </dev/null 2>&1 || true")
                  assert f"https://{host_}/api/v1/repos/org/repo/pulls" in out, out
              # no token in the persisted home
              rc, hits = host.execute(f"grep -rls 'test {name}-token' /var/lib/spaces/{name}/home")
              assert rc == 1, hits
              in_space(name, "command -v space-forge-check")
              # afk links the forge-prs skill
              in_space(name, 'grep -q forge-prs "$(readlink -f "$(command -v afk)")"')

      with subtest("without the forges the org's clones give up softly"):
          name = "geninf-space"
          unit = f"{name}-clone-org-git.geninf.io.service"
          host.wait_until_succeeds(f"nixos-container run {name} -- journalctl -u {unit} | grep -q 'trying again in 15 min'", timeout=120)
          assert space_root(name, f"systemctl show -p Result --value {unit}").strip() == "success"
          space_root(name, f"systemctl list-timers {name}-clone-org-git.geninf.io.timer | grep -q clone-org")

      with subtest("Dave's herdr: the spaces as machines, attached over ssh"):
          host.wait_for_unit("nixos-activation.service", "dave")
          # a retired space's entry the script made earlier goes, Dave's own stays
          import hashlib
          retired = hashlib.sha256(b"hyperconfig-space:agave").hexdigest()[:32]
          state = "/home/dave/.local/state/herdr/client"
          catalog = json.loads(host.succeed(f"cat {state}/endpoints.json"))
          catalog["ssh"] += [
              {"id": retired, "label": "agave", "target": "space-agave", "session": "default", "enabled": True},
              {"id": "0" * 32, "label": "mine", "target": "dave@example.org", "session": "default", "enabled": True},
          ]
          managed = json.loads(host.succeed(f"cat {state}/hyperconfig-spaces.json")) + [retired]
          host.succeed(f"echo {shlex.quote(json.dumps(catalog))} > {state}/endpoints.json")
          host.succeed(f"echo {shlex.quote(json.dumps(managed))} > {state}/hyperconfig-spaces.json")
          host.succeed("systemctl --user -M dave@ restart nixos-activation.service")
          out = host.succeed("runuser -u dave -- herdr machine list")
          assert "space-agave" not in out and "dave@example.org" in out, out
          out = host.succeed("runuser -u dave -- herdr machine list")
          print(out)
          for name, s in spaces.items():
              assert f"\tspace-{name}\t" in out, out
          host.succeed("install -d -m 0700 -o dave /home/dave/.ssh && install -m 0400 -o dave /etc/dave-ssh/id_ed25519 /home/dave/.ssh/id_ed25519")
          # what herdr's attach runs over ssh: the bridge, which starts the
          # space's herdr server on demand (`machine status` only checks)
          for name in spaces:
              host.execute(f"runuser -u dave -- timeout 20 ssh -o BatchMode=yes space-{name} 'exec herdr remote-client-bridge </dev/null'")
              host.wait_until_succeeds(f"nixos-container run {name} -- pgrep -u {name} -f 'herdr server'", timeout=30)
          out = host.succeed("runuser -u dave -- herdr machine status 2>&1")
          print(out)
          # all reached and their herdr servers found (status: ok)
          for name in spaces:
              line = next(l for l in out.splitlines() if f"\t{name}\t" in l)
              assert "error" not in line and "unreachable" not in line, out
          # Dave's login through the alias (the launchers' way)
          assert host.succeed("runuser -u dave -- ssh -o BatchMode=yes space-geninf-space id -un").strip() == "geninf-space"

      users = {"infra-space": "infra", **{n: n for n in spaces}}
      def system_path(name):
          # /etc/nixos-containers or /etc/containers, by stateVersion
          out = host.succeed(f"grep -hs ^SYSTEM_PATH= /etc/nixos-containers/{name}.conf /etc/containers/{name}.conf || true").strip()
          assert out, name
          return out.split("=", 1)[1]
      def leader(name):
          return host.succeed(f"machinectl show {name} -p Leader --value").strip()
      def switch(spec):
          out = host.succeed(f"/run/booted-system/specialisation/{spec}/bin/switch-to-configuration test 2>&1")
          print(out)
          return out
      def listed(out, what, unit):
          return any(l.startswith(f"{what} the following units: ") and unit in l for l in out.splitlines())

      with subtest("a change of the guests alone switches them in place, their users' processes kept"):
          procs = {}
          for name, user in users.items():
              # a long-running process of the user's own, outside any unit
              space_root(name, f"systemd-run --uid={user} --unit=marker sleep infinity")
              procs[name] = {"marker": space_root(name, "systemctl show -p MainPID --value marker.service").strip()}
          for name, s in spaces.items():
              # Dave's tmux in an ssh login, as the launchers start it
              peer.succeed(f"timeout 30 ssh -o BatchMode=yes -p {s['port']} {name}@${hostV6} \"tmux new -d -s main 'sleep 86400'\"")
              procs[name]["tmux"] = peer.succeed(f"timeout 30 ssh -o BatchMode=yes -p {s['port']} {name}@${hostV6} \"tmux display -p -t main '#{{pid}}'\"").strip()
              procs[name]["tmux-child"] = space_root(name, f"pgrep -o -u {name} -fx 'sleep 86400'").strip()
              # the herdr server the subtest above started
              host.wait_until_succeeds(f"nixos-container run {name} -- pgrep -u {name} -f 'herdr server'", timeout=30)
              procs[name]["herdr"] = space_root(name, f"pgrep -o -u {name} -f 'herdr server'").strip()
          leaders = {name: leader(name) for name in users}
          old = {name: system_path(name) for name in users}
          out = switch("guest-change")
          for name, user in users.items():
              unit = f"container@{name}.service"
              assert listed(out, "reloading", unit), (name, out)
              for what in ["stopping", "restarting", "starting"]:
                  assert not listed(out, what, unit), (name, what, out)
              host.succeed(f"systemctl is-active {unit}")
              assert leader(name) == leaders[name], name
              new = system_path(name)
              assert new != old[name], name
              assert space_root(name, "readlink -f /run/current-system").strip() == new, name
              assert space_root(name, "cat /etc/guest-change").strip() == "changed", name
              for what, pid in procs[name].items():
                  space_root(name, f"test -d /proc/{pid}")
              assert space_root(name, "systemctl show -p MainPID --value marker.service").strip() == procs[name]["marker"], name
          for name, s in spaces.items():
              in_space(name, "hello")
              out = peer.succeed(f"timeout 30 ssh -o BatchMode=yes -p {s['port']} {name}@${hostV6} tmux ls")
              assert out.startswith("main:"), (name, out)

      with subtest("one of the host's side restarts it into the new guest, also with clients knocking"):
          # Dave's herdr and ssh reconnect at once when the restart drops
          # them: a connection in the switch's window must not start the
          # container from the old unit (the old guest, the old credentials)
          peer.succeed("(while [ ! -e /tmp/knock-stop ]; do for p in ${lib.concatMapStringsSep " " (s: toString s.port) (lib.attrValues spaces)} 2223; do nc -z -w 1 ${hostV6} $p; done; sleep 0.05; done) >/dev/null 2>&1 &")
          before = leader("geninf-space")
          out = switch("host-change")
          assert listed(out, "stopping", "container@geninf-space.service") and listed(out, "starting", "container@geninf-space.service"), out
          host.wait_for_unit("container@geninf-space.service")
          host.wait_until_succeeds("nixos-container run geninf-space -- systemctl is-active multi-user.target", timeout=120)
          assert leader("geninf-space") != before
          new = system_path("geninf-space")
          assert space_root("geninf-space", "readlink -f /run/current-system").strip() == new, new
          assert space_root("geninf-space", "readlink -f /run/booted-system").strip() == new, new
          space_root("geninf-space", "test ! -e /etc/guest-change")
          # started by the new unit: its nspawn flag
          host.succeed("tr '\\0' '\\n' < /proc/$(systemctl show -p MainPID --value container@geninf-space.service)/cmdline | grep -qx --  --setenv=SPACE_TEST=1")
          peer.succeed("touch /tmp/knock-stop")
          peer.succeed("timeout 30 ssh -o BatchMode=yes -p ${toString spaces.geninf-space.port} geninf-space@${hostV6} id -un")
    '';
}
