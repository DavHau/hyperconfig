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
#   - published window: this host's nginx (only its uid) reaches the
#     guest's 8000-8099 on the veth address, not 8100; space-publish
#     forwards a 127.0.0.1-only app; the URL scheme in env, motd, skill
#     (nginx, login, TLS are som's ./publish.nix, checked live there);
#   - herdr: Dave's user activation saves the spaces as herdr machines
#     (`herdr machine list`, targets the ssh aliases `<name>-som`); the
#     bridge herdr runs over ssh at attach starts each guest's herdr
#     server, and `herdr machine status` then finds them ok; an entry of a
#     space no longer declared (retired) is removed, Dave's own kept, one
#     of the old naming relabelled in place (no duplicate);
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
  daemonTest = import ./test-daemon.nix { inherit pkgs; };
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
        # an idmappable store for the guests' own user namespaces
        daemonTest.hostModule
      ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
      virtualisation.tpm.enable = true;
      # an xHCI controller at a fixed address for ./usb-ports.nix: a stick
      # plugged into its port 1 goes into geninf-space, one in port 2 not
      virtualisation.qemu.options = [ "-device qemu-xhci,id=xhci,addr=0x1e" ];
      # what a stick or keyboard on the port must not reach (as on som and
      # amy): udisks' automount, LVM's event activation, logind's power
      # key, the kernel's Ctrl-Alt-Del (reboot.target)
      services.udisks2.enable = true;
      services.lvm.enable = true;
      # the guests' test builds' builder
      virtualisation.additionalPaths = [
        pkgs.pkgsStatic.busybox
        # check_no_setuid's binaries
        pkgs.libcap
      ];
      networking.nftables.enable = true;
      networking.useNetworkd = true;
      environment.systemPackages = [
        pkgs.netcat-openbsd
        pkgs.dnsutils
        pkgs.curl
      ];
      users.users.tenant.isNormalUser = true;
      # som's nginx, the published windows' front (./publish.nix, there on
      # hyperhermes' login): here only its uid, for the output gate
      services.nginx.enable = true;

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

      hyper.spaces = lib.mkMerge [
        (lib.genAttrs spaceNames (_: {
          enable = true;
          inherit address;
          meshInterface = "eth1";
          adminKeys.dave = pub "admin.pub";
        }))
        {
          # port 1 of the controller's buses (USB 2 or 3, whichever takes the stick)
          geninf-space.usbPorts = lib.mkForce (
            map (b: "0000:00:1e.0/usb${toString b}/${toString b}-1") (lib.range 1 8)
          );
          # Repo mode clones GitHub, which this test has no route to:
          # agave-setup would retry forever and fail every switch. The
          # space's machinery is what this test covers.
          agave-host.guestModules = [ { services.agave.repository = lib.mkForce null; } ];
        }
      ];

      # Dave on amy: his herdr gets the spaces as machines.
      users.users.dave = {
        isNormalUser = true;
        linger = true;
      };
      hyper.spacesClient = {
        herdrUser = "dave";
        spaces = lib.mapAttrs' (
          name: r:
          lib.nameValuePair "${name}-som" {
            space = name;
            machine = "som";
            herdrId = name;
            inherit (r) sshPort;
            user = name;
            inherit address;
            hostKey = pub "hostkey-${name}.pub";
          }
        ) registry;
      };

      # A later deploy: a change of the guests alone (every space and
      # infra-space), switched in place, and one of geninf-space's host side
      # (an nspawn flag), which restarts it.
      specialisation = {
        # the rollback: geninf-space without its own user namespace
        no-userns.configuration.hyper.spaces.geninf-space.privateUsers = false;
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
      clan.core.vars.generators.openrouter.files.apikey = { };
      environment.etc = {
        "test-vars/infra-space-ssh/id_ed25519" = secret (isKeys + "/infra-space");
        "test-vars/infra-space-github/id_ed25519" = fake "infra-space-github";
        "test-vars/infra-space-secrets-github/id_ed25519" = fake "infra-space-secrets-github";
        "test-vars/agave-geninf-ro/id_ed25519" = fake "agave-geninf-ro";
        "test-vars/infra-space-hostkey/ssh_host_ed25519_key" = secret (isKeys + "/hostkey-memberA");
        "test-vars/inference-api-key/token" = fake "p0-token";
        "test-vars/teamclaude-api-key/key" = fake "teamclaude-key";
        "test-vars/openrouter/apikey" = fake "openrouter-key";
        "test-vars/space-geninf-space-hostkey/ssh_host_ed25519_key" = secret (
          keys + "/hostkey-geninf-space"
        );
        "test-vars/space-geninf-space-root-ssh/id_ed25519" = fake "geninf-space-root-ssh";
        "test-vars/space-geninf-space-root-ssh-agave/id_ed25519" = fake "geninf-space-root-ssh-agave";
        "test-vars/space-geninf-space-git-geninf/id_ed25519" = fake "geninf-space-git-geninf";
        "test-vars/space-geninf-space-git-clan-lol/id_ed25519" = fake "geninf-space-git-clan-lol";
        "test-vars/space-geninf-space-token-geninf/token" = fake "geninf-space-token-geninf";
        "test-vars/space-geninf-space-token-clan-lol/token" = fake "geninf-space-token-clan-lol";
        "test-vars/space-geninf-space-token-ci/token" = fake "geninf-space-token-ci";
        "test-vars/space-agave-host-hostkey/ssh_host_ed25519_key" = secret (keys + "/hostkey-agave-host");
        "test-vars/space-agave-host-teamclaude/key" = fake "agave-host-teamclaude";
        "test-vars/space-agave-host-github/id_ed25519" = fake "agave-host-github";
        "test-vars/space-agave-host-tenant-ssh/id_ed25519" = fake "agave-host-tenant-ssh";
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
          "geninf-space": {"p0-api-key", "teamclaude-api-key", "openrouter-api-key", "root-ssh", "root-ssh-agave", "git-geninf", "git-clan-lol", "token-geninf", "token-clan-lol", "token-ci"},
          "agave-host": {"p0-api-key", "teamclaude-api-key", "openrouter-api-key", "teamclaude-key", "agave-geninf-ro"},
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

      ${daemonTest.pythonHelpers}

      start_all()
      peer.wait_for_unit("listener.service")
      for name in ["infra-space", *spaces]:
          host.wait_for_unit(f"container@{name}.service")
      for name in spaces:
          host.wait_until_succeeds(f"nixos-container run {name} -- systemctl is-active sshd.service {name}-secrets.service", timeout=120)

      peer.succeed("install -d -m 0700 /root/.ssh && install -m 0400 ${keys}/admin /root/.ssh/id_ed25519")
      with subtest("every container is an untrusted client of the host's nix-daemon, root included"):
          for name, user in [("infra-space", "infra"), *((n, n) for n in spaces)]:
              check_untrusted(host, name, user, "${pkgs.pkgsStatic.busybox}")
          # the home keeps its on-disk owner, the guest sees its user
          assert host.succeed("stat -c %u /var/lib/spaces/geninf-space/home").strip() == "${toString registry.geninf-space.uid}"
          assert in_space("geninf-space", "stat -c %U ~").strip() == "geninf-space"
          in_space("geninf-space", "touch ~/owned && test -O ~/owned")
          assert host.succeed("stat -c %u /var/lib/spaces/geninf-space/home/owned").strip() == "${toString registry.geninf-space.uid}"
          # the TPM ACL names the guest user's host uid
          acl = host.succeed("getfacl -n /dev/tpmrm0")
          assert "\nuser:${
            toString (1342177280 + 65536 * registry.geninf-space.index + registry.geninf-space.uid)
          }:rw" in acl, acl
          # no host user walks into a container's tree
          assert host.succeed("stat -c %a /var/lib/nixos-containers").strip() == "700"

      with subtest("a setuid or file-capability binary of the guest's root runs as no one's root"):
          check_no_setuid(host, "geninf-space", "geninf-space", "/var/lib/spaces/geninf-space/home", "/home/geninf-space")
          check_no_setuid(host, "infra-space", "infra", "/var/lib/infra-space/home", "/home/infra")
          assert host.succeed("stat -c %a /var/lib/spaces").strip() == "700"
          # the guest's root writes its profiles and gcroots too: nosuid,nodev
          for c in ("geninf-space", "infra-space"):
              for d in ("profiles", "gcroots"):
                  opts = host.succeed(f"findmnt -n -o VFS-OPTIONS --mountpoint /nix/var/nix/{d}/per-container/{c}").split(",")
                  assert "nosuid" in opts and "nodev" in opts, (c, d, opts)

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
              out = space_root(name, f"findmnt -n -o TARGET,FSTYPE -T /run/{name}/secrets/p0-api-key").split()
              assert out == ["/run", "tmpfs"], out
              space_root(name, f"test ! -e /run/{name}/secrets/ssh-host-key")
              space_root(name, "test ! -e /run/infra-space")
              # `[c]...`: the pattern never matches the command line itself,
              # which `nixos-container run` leaves in a transient unit in /run
              needle = "[" + is_key[0] + "]" + re.escape(is_key[1:])
              # rc 2 for nspawn's /run/host/incoming only: host root's 0700
              # directory, closed to the guest's root in its own user
              # namespace
              rc, hits = host.execute(f"nixos-container run {name} -- grep -rlE {shlex.quote(needle)} /run /etc /home /var /root 2>/tmp/grep-errors")
              errors = host.succeed("cat /tmp/grep-errors").strip().splitlines()
              assert rc in (1, 2) and hits.strip() == "", (name, rc, hits)
              assert all(e == "grep: /run/host/incoming: Permission denied" for e in errors), errors
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

      with subtest("published window: this host's nginx reaches 8000-8099 only"):
          name = "geninf-space"
          g = spaces[name]["v4"]
          as_nginx = "setpriv --reuid=nginx --regid=nginx --clear-groups --"
          def serve(unit, *argv):
              space_root(name, f"systemd-run --uid={name} --gid={name} --unit={unit} -p WorkingDirectory=/tmp /run/current-system/sw/bin/" + " ".join(argv))
          serve("pub-8095", "python3 -m http.server 8095 --bind 0.0.0.0")
          serve("pub-8100", "python3 -m http.server 8100 --bind 0.0.0.0")
          host.wait_until_succeeds(f"curl -sf --max-time 5 http://{g}:8095/", timeout=60)
          host.wait_until_succeeds(f"curl -sf --max-time 5 http://{g}:8100/", timeout=60)
          host.succeed(f"{as_nginx} curl -sf --max-time 5 http://{g}:8095/")
          host.fail(f"{as_nginx} curl -sf --max-time 5 http://{g}:8100/")
          host.fail(f"runuser -u tenant -- curl -sf --max-time 5 http://{g}:8095/")
          # an app on 127.0.0.1 only, through space-publish
          serve("pub-8096", "python3 -m http.server 8096 --bind 127.0.0.1")
          space_root(name, "sh -c 'for i in $(seq 50); do ss -Hltn sport = :8096 | grep -q . && exit 0; sleep 0.2; done; exit 1'")
          host.fail(f"{as_nginx} curl -sf --max-time 5 http://{g}:8096/")
          serve("pub-fwd", "space-publish 8096")
          host.wait_until_succeeds(f"{as_nginx} curl -sf --max-time 5 http://{g}:8096/", timeout=30)
          out = space_root(name, "journalctl -u pub-fwd -o cat")
          assert "https://8096.geninf-space.davhau.fyi/" in out, out
          space_fails(name, "space-publish 8100")
          # what the agent is told
          assert in_space(name, "echo $SPACE_PUBLIC_URL_TEMPLATE").strip() == "https://{port}.geninf-space.davhau.fyi"
          in_space(name, 'grep -q space-publish "$(readlink -f "$(command -v afk)")"')
          space_root(name, "sh -c 'grep -q https://{port}.geninf-space.davhau.fyi $(grep -o \"motd=[^ ]*\" /etc/pam.d/sshd | cut -d= -f2)'")
          space_root(name, "systemctl stop pub-8095 pub-8100 pub-8096 pub-fwd")

      with subtest("agave-host: this host's nginx reaches Agave's 80 and 443 (the SNI front), nobody else"):
          g = spaces["agave-host"]["v4"]
          as_nginx = "setpriv --reuid=nginx --regid=nginx --clear-groups --"
          host.wait_until_succeeds("nixos-container run agave-host -- systemctl is-active agave.service", timeout=180)
          # the public half of the guest's host key, where Agave reads it
          assert space_root("agave-host", "cat /etc/ssh/ssh_host_ed25519_key.pub").split()[:2] == spaces["agave-host"]["hostKey"].split()[:2]
          for port in (80, 443):
              host.wait_until_succeeds(f"{as_nginx} nc -z -w 5 {g} {port}", timeout=120)
              host.fail(f"runuser -u tenant -- nc -z -w 5 {g} {port}")
          # the tunnel login is the second user sshd lets in
          out = space_root("agave-host", "grep -i '^AllowUsers' /etc/ssh/sshd_config").split()
          assert sorted(out[1:]) == ["agave-host", "t-infra-tun"], out
          space_root("agave-host", "systemctl is-active sshd.service")
          # the push key and the fleet's root key: root's system credentials
          # only, never the login user's
          for cred in ("github", "tenant-ssh"):
              assert space_root("agave-host", f"cat /run/credentials/@system/{cred}").strip() == f"test agave-host-{cred}", cred
              space_fails("agave-host", f"cat /run/credentials/@system/{cred}")
              space_root("agave-host", f"test ! -e /run/agave-host/secrets/{cred}")

      with subtest("without the forges the org's clones give up softly"):
          name = "geninf-space"
          unit = f"{name}-clone-org-git.geninf.io.service"
          host.wait_until_succeeds(f"nixos-container run {name} -- journalctl -u {unit} | grep -q 'trying again in 15 min'", timeout=120)
          assert space_root(name, f"systemctl show -p Result --value {unit}").strip() == "success"
          space_root(name, f"systemctl list-timers {name}-clone-org-git.geninf.io.timer | grep -q clone-org")

      with subtest("usb ports: a device on a listed port, only it, only while plugged"):
          import os
          def leader(name):
              return host.succeed(f"machinectl show {name} -p Leader --value").strip()
          cg = "/sys/fs/cgroup/machine.slice/container@geninf-space.service/payload/init.scope/cgroup.procs"
          def guest_cmd(cmd):
              # in the container's cgroup (its DeviceAllow) and namespaces, as its root
              return "sh -c " + shlex.quote(f"echo $$ > {cg} && exec nsenter --all -t {leader('geninf-space')} -- sh -c " + shlex.quote(cmd))
          def as_guest(cmd, check=True):
              return host.succeed(guest_cmd(cmd)) if check else host.execute(guest_cmd(cmd))
          def plug(port, ident, img=None, size=1 << 20):
              if img is None:
                  img = os.path.join(host.state_dir, f"{ident}.img")
                  with open(img, "wb") as f:
                      f.truncate(size)
              host.send_monitor_command(f"drive_add 0 if=none,id={ident},format=raw,file={img}")
              host.send_monitor_command(f"device_add usb-storage,bus=xhci.0,port={port},drive={ident},id={ident}")
          def unplug(ident):
              host.send_monitor_command(f"device_del {ident}")
          allow = host.succeed("systemctl show -p DeviceAllow container@geninf-space.service")
          assert "block-sd" not in allow and "usb_device" not in allow and "hidraw" not in allow, allow
          base = int(host.succeed(f"cat /proc/{leader('geninf-space')}/uid_map").split()[1])
          tpm_owner = host.succeed("stat -c %u:%g /dev/tpmrm0").strip()
          # the guest's root plants a link where the node will go
          as_guest("ln -sf /dev/tpmrm0 /dev/sda")
          plug(1, "stick1")
          host.wait_until_succeeds("test -b /dev/sda", timeout=60)
          try:
              host.wait_until_succeeds("systemctl is-active 'space-usb@geninf-space:sda.service'", timeout=60)
          finally:
              print(host.execute("udevadm info /dev/sda | grep -E 'DEVPATH|SYSTEMD'; journalctl -b --no-pager -u 'space-usb*' | tail -40")[1])
          print(host.succeed("udevadm info -q path /sys/class/block/sda; systemctl list-units 'space-usb*'"))
          assert host.succeed("stat -c %u:%g /dev/tpmrm0").strip() == tpm_owner
          # the rewritten list keeps the unit's own entries
          allow = host.succeed("systemctl show -p DeviceAllow container@geninf-space.service")
          assert "/dev/tpmrm0" in allow and "/dev/net/tun" in allow and "8:0" in allow, allow
          out = as_guest("stat -c '%F %t:%T %u:%g %a' /dev/sda").strip()
          assert out == "block special file 8:0 ${toString registry.geninf-space.uid}:${toString registry.geninf-space.uid} 660", out
          assert host.succeed("stat -c '%u:%g' /proc/" + leader("geninf-space") + "/root/dev/sda").strip() == f"{base + ${toString registry.geninf-space.uid}}:{base + ${toString registry.geninf-space.uid}}"
          # the space's user, not root, reads it
          as_guest("runuser -u geninf-space -- dd if=/dev/sda of=/dev/null bs=512 count=1")
          as_guest("dd if=/dev/sda of=/dev/null bs=512 count=1")
          # its usb_device node too, owned by the guest's root
          host.wait_until_succeeds("systemctl list-units --plain --no-legend 'space-usb@geninf-space:usb-*' | grep -q active", timeout=30)
          as_guest("ls /dev/bus/usb/*/* && for n in /dev/bus/usb/*/*; do exec 3<$n || exit 1; done")
          # a hard link the guest keeps, and the node itself, open nothing after unplug
          as_guest("ln /dev/sda /dev/keep")
          unplug("stick1")
          host.wait_until_succeeds(guest_cmd("test ! -e /dev/sda"), timeout=60)
          host.wait_until_succeeds("! systemctl -q is-active 'space-usb@geninf-space:sda.service'", timeout=60)
          # the next device on another (unlisted) port gets the same number
          plug(2, "stick2")
          host.wait_until_succeeds("test -b /dev/sda", timeout=60)
          assert host.succeed("stat -c %t:%T /dev/sda").strip() == "8:0"
          host.succeed("! systemctl -q is-active 'space-usb@geninf-space:sda.service'")
          rc, out = as_guest("dd if=/dev/keep of=/dev/null bs=512 count=1 2>&1", check=False)
          assert rc != 0 and "Operation not permitted" in out, (rc, out)
          as_guest("rm /dev/keep")
          unplug("stick2")
          host.wait_until_succeeds("! test -e /dev/sda", timeout=60)
          # a directory on the way swapped for a link: refused, nothing made there
          as_guest("rm -rf /dev/bus && mkdir -p /tmp/elsewhere && ln -s /tmp/elsewhere /dev/bus")
          plug(1, "stick3")
          host.wait_until_succeeds("systemctl is-active 'space-usb@geninf-space:sda.service'", timeout=60)
          host.wait_until_succeeds("systemctl list-units --plain --no-legend --all 'space-usb@geninf-space:usb-*' | grep -q failed", timeout=30)
          as_guest("test -z \"$(ls -A /tmp/elsewhere)\"")
          as_guest("rm /dev/bus")
          # a restarted container gets the plugged devices again
          before = leader("geninf-space")
          host.succeed("systemctl restart container@geninf-space.service")
          host.wait_until_succeeds("nixos-container run geninf-space -- systemctl is-active multi-user.target sshd.service", timeout=120)
          assert leader("geninf-space") != before
          host.wait_until_succeeds(f"test -b /proc/{leader('geninf-space')}/root/dev/sda", timeout=60)
          as_guest("dd if=/dev/sda of=/dev/null bs=512 count=1")
          host.wait_until_succeeds(f"ls /proc/{leader('geninf-space')}/root/dev/bus/usb/*/*", timeout=30)
          unplug("stick3")
          host.wait_until_succeeds(f"! test -e /proc/{leader('geninf-space')}/root/dev/sda", timeout=60)
          allow = host.succeed("systemctl show -p DeviceAllow container@geninf-space.service")
          assert "/dev/block/" not in allow, allow
          assert "/dev/tpmrm0" in allow and "/dev/net/tun" in allow, allow
          # the revocation retry: nothing pending, done at once
          host.succeed("systemctl start space-usb-revoke@geninf-space.service")
          assert host.succeed("systemctl show -p Result --value space-usb-revoke@geninf-space.service").strip() == "success"
          host.succeed("! ls /run/space-usb/geninf-space | grep -q revoking")
          import time
          def stays(cmd, seconds=5):
              # cmd keeps succeeding for a while (1 s steps)
              for _ in range(seconds):
                  host.succeed(cmd)
                  time.sleep(1)

          # a stick with an LVM PV: on another port this host probes it
          # (LVM2_member); on the listed port neither blkid, LVM, md nor
          # udisks touch it
          lvm_img = os.path.join(host.state_dir, "lvm.img")
          with open(lvm_img, "wb") as f:
              f.truncate(32 << 20)
          plug(2, "lvm1", img=lvm_img)
          host.wait_until_succeeds("test -b /dev/sda", timeout=60)
          host.succeed("pvcreate -y /dev/sda && vgcreate spusbtest /dev/sda && lvcreate -y -L 4M -n lv spusbtest && vgchange -an spusbtest")
          forget = "rm -rf /run/lvm/pvs_online/* /run/lvm/vgs_online/* /run/lvm/pvs_lookup/*"
          host.succeed(forget)
          host.succeed("udevadm trigger --settle --action=add /dev/sda")
          host.succeed("udevadm info -q property /dev/sda | grep -qx ID_FS_TYPE=LVM2_member")
          # the baseline: on an unlisted port this host's LVM activates
          # it, and udev links it under /dev/disk
          host.wait_until_succeeds("test -e /dev/spusbtest/lv", timeout=30)
          host.succeed("find /dev/disk -lname '*/sda' | grep -q by-path")
          host.succeed("vgchange -an spusbtest")
          host.wait_until_succeeds("! dmsetup ls | grep -q spusbtest", timeout=30)
          unplug("lvm1")
          host.wait_until_succeeds("! test -e /dev/sda", timeout=60)
          # forget what LVM saw on the other port, so a scan would activate again
          host.succeed(forget)
          plug(1, "lvm2", img=lvm_img)
          host.wait_until_succeeds("systemctl is-active 'space-usb@geninf-space:sda.service'", timeout=60)
          props = host.succeed("udevadm info -q property /dev/sda")
          print(props)
          assert "ID_FS_TYPE=" not in props and "UDISKS_IGNORE=1" in props and "UDISKS_AUTO=0" in props, props
          # no /dev/disk/by-* link (by-id: ZFS's import dir on som and amy)
          assert "DEVLINKS=" not in props, props
          host.succeed("test -z \"$(find /dev/disk -lname '*/sda')\"")
          stays("! test -e /dev/spusbtest/lv && ! dmsetup ls | grep -q spusbtest && ! ls /run/lvm/pvs_online | grep -q .")
          host.wait_until_succeeds("udisksctl info -b /dev/sda | grep -Eq 'HintIgnore: +true'", timeout=30)
          info = host.succeed("udisksctl info -b /dev/sda")
          assert re.search(r"HintAuto:\s+false", info) and re.search(r"HintSystem:\s+true", info), info
          assert "/dev/sda" not in host.succeed("cat /proc/mounts")
          as_guest("dd if=/dev/sda of=/dev/null bs=512 count=1")
          unplug("lvm2")
          host.wait_until_succeeds(f"! test -e /proc/{leader('geninf-space')}/root/dev/sda", timeout=60)

          # a keyboard on the port: the guest reads its reports by hidraw,
          # this host's kernel and logind act on none of its keys
          # Ctrl-Alt-Del at once, before udev inhibits it: does nothing
          # here (nor from any keyboard, nor the target started by hand)
          cursor = host.succeed("journalctl -n0 --show-cursor | tail -1 | sed 's/^-- cursor: //'").strip()
          host.send_monitor_command("device_add usb-kbd,bus=xhci.0,port=1,id=kbd1")
          host.send_key("ctrl-alt-delete")
          host.succeed("systemctl start ctrl-alt-del.target")
          assert host.succeed("readlink /etc/systemd/system/ctrl-alt-del.target").strip().endswith("space-usb-ctrl-alt-del.target")
          stays("! systemctl -q is-active reboot.target poweroff.target && systemctl -q is-active multi-user.target")
          jlog = host.succeed(f"journalctl --after-cursor={shlex.quote(cursor)} --no-pager")
          assert "reboot.target" not in jlog and "Reboot" not in jlog, jlog
          host.succeed("systemctl -q is-active space-usb-ctrl-alt-del.target")
          host.succeed("systemctl stop space-usb-ctrl-alt-del.target")
          find_input = "for d in /sys/class/input/input*; do readlink -f $d | grep -q 0000:00:1e.0 && echo $d; done"
          host.wait_until_succeeds(f"test -n \"$({find_input})\"", timeout=60)
          inputs = host.succeed(find_input).split()
          host.wait_until_succeeds(" && ".join(f"grep -qx 1 {d}/inhibited" for d in inputs), timeout=30)
          for d in inputs:
              for ev in host.succeed(f"ls -d {d}/event* 2>/dev/null || true").split():
                  props = host.succeed(f"udevadm info -q property /dev/input/{os.path.basename(ev)}")
                  assert "LIBINPUT_IGNORE_DEVICE=1" in props, props
                  tags = [l for l in props.splitlines() if l.startswith("CURRENT_TAGS=")]
                  assert not any("power-switch" in t for t in tags), props
          host.wait_until_succeeds(guest_cmd("ls /dev/hidraw*"), timeout=60)
          hidraw = as_guest("ls /dev/hidraw*").split()[0]
          as_guest(f"(timeout 60 head -c 8 {hidraw} > /tmp/hid.out 2>&1 &) </dev/null >/dev/null 2>&1")
          time.sleep(1)
          cursor = host.succeed("journalctl -n0 --show-cursor | tail -1 | sed 's/^-- cursor: //'").strip()
          host.send_key("ctrl-alt-delete")
          host.send_key("power")
          host.wait_until_succeeds(guest_cmd("test -s /tmp/hid.out"), timeout=30)
          stays("! systemctl -q is-active reboot.target poweroff.target ctrl-alt-del.target && systemctl -q is-active multi-user.target")
          jlog = host.succeed(f"journalctl --after-cursor={shlex.quote(cursor)} --no-pager")
          assert "Power key pressed" not in jlog and "Ctrl-Alt-Del" not in jlog and "ctrl-alt-del" not in jlog, jlog
          # nor did it reach the kernel's VT keyboard (systemd would start
          # the no-op target again)
          host.succeed("! systemctl -q is-active space-usb-ctrl-alt-del.target")
          host.send_monitor_command("device_del kbd1")
          host.wait_until_succeeds(f"test -z \"$({find_input})\"", timeout=60)
          # a network adapter on the port: into the guest's netns, DHCP on
          # it there, no default route or DNS from it; the host keeps none
          host.send_monitor_command("netdev_add user,id=usbnet0,net=10.95.117.0/24")
          host.send_monitor_command("device_add usb-net,bus=xhci.0,port=1,netdev=usbnet0,id=nic1")
          host.wait_until_succeeds("nixos-container run geninf-space -- ip -4 -br addr show | grep -q '^usb.*10.95.117.'", timeout=90)
          routes = space_root("geninf-space", "ip -4 route")
          assert not any(l.startswith("default") and "dev usb" in l for l in routes.splitlines()), routes
          assert "10.95.117" not in host.succeed("ip -4 addr; ip -4 route")
          assert "10.95.117" not in space_root("geninf-space", "cat /etc/resolv.conf")
          host.fail("for n in /sys/class/net/*; do readlink -f $n | grep -q 0000:00:1e.0 && exit 0; done; exit 1")
          # replug: a new interface, moved again
          host.send_monitor_command("device_del nic1")
          host.wait_until_succeeds("! nixos-container run geninf-space -- ip -br link | grep -q ^usb", timeout=60)
          host.send_monitor_command("device_add usb-net,bus=xhci.0,port=1,netdev=usbnet0,id=nic2")
          host.wait_until_succeeds("nixos-container run geninf-space -- ip -4 -br addr show | grep -q '^usb.*10.95.117.'", timeout=90)
          # a hostile netmask: the prefix route stays in the guest's
          # table 4242, ignored when shorter than /16
          rules = space_root("geninf-space", "ip -4 rule")
          assert "4242" in rules and "suppress_prefixlength 15" in rules, rules
          # only for private and link-local destinations
          for to in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"):
              assert f"to {to} lookup 4242" in rules, rules
          assert "from all lookup 4242" not in rules, rules
          assert "10.95.117" not in space_root("geninf-space", "ip -4 route show table main"), rules
          assert "10.95.117.0/24" in space_root("geninf-space", "ip -4 route show table 4242")
          # a container restart: moved into the new one
          host.succeed("systemctl restart container@geninf-space.service")
          host.wait_until_succeeds("nixos-container run geninf-space -- ip -4 -br addr show | grep -q '^usb.*10.95.117.'", timeout=120)
          # the guest reboots itself (nspawn exits 133, the unit restarts
          # it): devices (the adapter's usb_device node; qemu's port 1 is
          # taken by it) and adapter come back without anyone's help
          host.wait_until_succeeds(f"ls /proc/{leader('geninf-space')}/root/dev/bus/usb/*/*", timeout=60)
          before = leader("geninf-space")
          host.execute("timeout 30 nixos-container run geninf-space -- systemctl reboot")
          host.wait_until_succeeds(f"l=$(machinectl show geninf-space -p Leader --value) && [ -n \"$l\" ] && [ \"$l\" != {before} ]", timeout=120)
          host.wait_until_succeeds("nixos-container run geninf-space -- systemctl is-active multi-user.target", timeout=120)
          host.wait_until_succeeds(f"ls /proc/{leader('geninf-space')}/root/dev/bus/usb/*/*", timeout=60)
          as_guest("for n in /dev/bus/usb/*/*; do exec 3<$n || exit 1; done")
          host.wait_until_succeeds("nixos-container run geninf-space -- ip -4 -br addr show | grep -q '^usb.*10.95.117.'", timeout=120)
          # powered off from inside: the adapter returns to this host under
          # a name of ours, down and unmanaged; started again, all is back
          host.execute("timeout 30 nixos-container run geninf-space -- systemctl poweroff")
          host.wait_until_succeeds("! systemctl -q is-active container@geninf-space.service", timeout=120)
          host.wait_until_succeeds("ip -br link | grep -q '^spusb[0-9]'", timeout=60)
          link = host.succeed("ip -br link | grep '^spusb[0-9]'")
          assert "DOWN" in link, link
          assert "10.95.117" not in host.succeed("ip -4 addr")
          host.succeed("systemctl start container@geninf-space.service")
          host.wait_until_succeeds("nixos-container run geninf-space -- systemctl is-active multi-user.target", timeout=120)
          host.wait_until_succeeds(f"ls /proc/{leader('geninf-space')}/root/dev/bus/usb/*/*", timeout=60)
          host.wait_until_succeeds("nixos-container run geninf-space -- ip -4 -br addr show | grep -q '^usb.*10.95.117.'", timeout=120)
          host.fail("ip -br link | grep -q '^spusb[0-9]'")
          host.send_monitor_command("device_del nic2")

      with subtest("Dave's herdr: the spaces as machines, attached over ssh"):
          host.wait_for_unit("nixos-activation.service", "dave")
          # a retired space's entry the script made earlier goes (also when
          # herdr had it selected), Dave's own stays; an entry of the old
          # naming (label = space name, managed list without labels) is
          # relabelled in place, never added a second time
          import hashlib
          retired = hashlib.sha256(b"hyperconfig-space:agave").hexdigest()[:32]
          state = "/home/dave/.local/state/herdr/client"
          catalog = json.loads(host.succeed(f"cat {state}/endpoints.json"))
          for e in catalog["ssh"]:
              e["label"] = e["target"].removesuffix("-som")
          catalog["ssh"] += [
              {"id": retired, "label": "agave", "target": "space-agave", "session": "default", "enabled": True},
              {"id": "0" * 32, "label": "mine", "target": "dave@example.org", "session": "default", "enabled": True},
          ]
          catalog["selected_profile"] = retired
          managed = list(json.loads(host.succeed(f"cat {state}/hyperconfig-spaces.json"))) + [retired]
          host.succeed(f"echo {shlex.quote(json.dumps(catalog))} > {state}/endpoints.json")
          host.succeed(f"echo {shlex.quote(json.dumps(managed))} > {state}/hyperconfig-spaces.json")
          host.succeed("systemctl --user -M dave@ restart nixos-activation.service")
          out = host.succeed("runuser -u dave -- herdr machine list")
          print(out)
          assert "space-agave" not in out and "dave@example.org" in out, out
          for name in spaces:
              lines = [l for l in out.splitlines() if f"\t{name}-som\t" in l]
              assert len(lines) == 1 and f"\t{name} (som)\t" in lines[0], out
          host.succeed("install -d -m 0700 -o dave /home/dave/.ssh && install -m 0400 -o dave /etc/dave-ssh/id_ed25519 /home/dave/.ssh/id_ed25519")
          # what herdr's attach runs over ssh: the bridge, which starts the
          # space's herdr server on demand (`machine status` only checks)
          for name in spaces:
              host.execute(f"runuser -u dave -- timeout 20 ssh -o BatchMode=yes {name}-som 'exec herdr remote-client-bridge </dev/null'")
              host.wait_until_succeeds(f"nixos-container run {name} -- pgrep -u {name} -f 'herdr server'", timeout=30)
          # exits 1 for Dave's own placeholder entry (example.org, no DNS
          # here); the spaces' lines are what counts
          _, out = host.execute("runuser -u dave -- herdr machine status 2>&1")
          print(out)
          # all reached and their herdr servers found (status: ok)
          for name in spaces:
              line = next(l for l in out.splitlines() if f"\t{name} (som)\t" in l)
              assert "error" not in line and "unreachable" not in line, out
          # Dave's login through the alias (the launchers' way)
          assert host.succeed("runuser -u dave -- ssh -o BatchMode=yes geninf-space-som id -un").strip() == "geninf-space"

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
          peer.succeed("(while [ ! -e /tmp/knock-stop ]; do for p in ${
            lib.concatMapStringsSep " " (s: toString s.port) (lib.attrValues spaces)
          } 2223; do nc -z -w 1 ${hostV6} $p; done; sleep 0.05; done) >/dev/null 2>&1 &")
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

      with subtest("rollback: privateUsers off, owners unchanged, no idmap, the home still nosuid"):
          switch("no-userns")
          host.wait_for_unit("container@geninf-space.service")
          host.wait_until_succeeds("nixos-container run geninf-space -- systemctl is-active multi-user.target", timeout=120)
          uid_map = host.succeed(f"cat /proc/{leader('geninf-space')}/uid_map").split()
          assert uid_map[:2] == ["0", "0"], uid_map
          flags = host.succeed("tr '\\0' '\\n' < /proc/$(systemctl show -p MainPID --value container@geninf-space.service)/cmdline")
          assert "idmap" not in flags and "--bind=/var/lib/spaces/geninf-space/home:/home/geninf-space" in flags, flags
          # ownership mapped, never chowned: the tree is still root's
          assert host.succeed("stat -c %u /var/lib/nixos-containers/geninf-space").strip() == "0"
          assert host.succeed("stat -c %u /var/lib/spaces/geninf-space/home").strip() == "${toString registry.geninf-space.uid}"
          assert in_space("geninf-space", "stat -c %U ~/owned").strip() == "geninf-space"
          opts = host.succeed("findmnt -n -o VFS-OPTIONS --mountpoint /var/lib/spaces/geninf-space/home").split(",")
          assert "nosuid" in opts and "nodev" in opts, opts
          peer.succeed("timeout 30 ssh -o BatchMode=yes -p ${toString spaces.geninf-space.port} geninf-space@${hostV6} id -un")
    '';
}
