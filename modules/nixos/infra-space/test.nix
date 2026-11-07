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
# itself reaches.
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
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      # the test build's builder, in the store the daemon serves (no
      # substituters in the sandbox)
      virtualisation.additionalPaths = [ pkgs.pkgsStatic.busybox ];
      # as on som and amy (../encrypted-dns.nix; clan's networkd)
      networking.nftables.enable = true;
      networking.useNetworkd = true;
      environment.systemPackages = [ pkgs.netcat-openbsd ];

      hyper.infraSpace = {
        enable = true;
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
        ];
      };

      environment.etc = {
        "test-vars/infra-space-ssh/id_ed25519" = secret (keys + "/infra-space");
        "test-vars/infra-space-github/id_ed25519" = secret (pkgs.writeText "github" "not a key\n");
        "test-vars/infra-space-age/key.txt" = secret (pkgs.writeText "age" "not a key\n");
        "test-vars/infra-space-hostkey/ssh_host_ed25519_key" = secret (keys + "/hostkey-${me}");
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
              guest_root(m, "journalctl -u infra-space-clone.service | grep -q 'trying again at next boot'")
    '';
}
