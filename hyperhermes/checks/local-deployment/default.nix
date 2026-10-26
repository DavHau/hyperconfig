# nixosModules.local-container end to end, with the example's own
# container config (../../example/hermes.nix: alice, with a slot), on two
# hosts booting side by side: `machine` runs systemd-networkd and the
# container the nftables firewall; `nm` runs NetworkManager and the
# container the iptables firewall, without the slot (slots bring their
# nftables tables, ../../modules/slots). Every check runs from the HOST,
# as a browser on the workstation would. On both:
# - the secrets exist after the container's first boot, alice's dex
#   password among them,
# - alice signs in to her dashboard at dex (browser and app sign-in) and
#   ends on authenticated dashboard API calls,
# - an app alice publishes on her first private port answers at
#   http://30010.alice.hermes.localhost:8473/ after her sign-in there,
# - a peer on the host's LAN routing to the container's address reaches
#   it (ping), but not its web front.
# On `machine`:
# - alice starts her slot (a container inside the container) and gets in
#   by ssh; its port 80 answers at http://slot.alice.hermes.localhost:8473/,
# - `slot info` and the skill call the slot's IPv6 private,
# - alice cannot change her key directory, and a key.pub link to a
#   root-only file (what earlier versions let her leave) stops her slot
#   start without leaking the file; the secrets unit replaces it.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  common = import ../slots/common.nix { inherit pkgs; };
  domain = "hermes.localhost";
  port = 8473;
  name = "hyperhermes";
  alicePrivate = 30010;
  slot4 = "10.43.1.2";
  python = pkgs.python3.withPackages (ps: [ ps.requests ]);
  localAddress = "10.233.73.2";
  nmHostAddress = "10.233.74.1";
  nmLocalAddress = "10.233.74.2";

  # The container config both hosts share.
  deployment = {
    imports = [ ../../example/hermes.nix ];
    # The agents' venv is not under test.
    services.hyperhermes.pythonPackages = _: [ ];
    environment.systemPackages = [ pkgs.curl ];
  };

  # The slot's port 80, answered from inside the slot (its bootstrap
  # firewall flushed); run in the outer container.
  slotHttp = pkgs.writeShellScript "slot-http" ''
    set -eu
    leader=$(machinectl show alice -p Leader --value)
    ${pkgs.util-linux}/bin/nsenter -t "$leader" -n ${pkgs.nftables}/bin/nft flush ruleset
    systemd-run --unit=slot-http ${pkgs.util-linux}/bin/nsenter -t "$leader" -a \
      ${pkgs.socat}/bin/socat TCP-LISTEN:80,fork,reuseaddr EXEC:'${common.responder} alice-http'
  '';
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-local-deployment";
  globalTimeout = 1800;

  nodes.machine = {
    imports = [
      self.nixosModules.local-container
      # The slots need a read-only store image (idmapped mounts) and a
      # stand-in for nix-env that writes the profile links nix cannot.
      common.slotHost
    ];
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    virtualisation.diskSize = 8192;
    environment.systemPackages = [ pkgs.curl ];

    services.hyperhermes.localContainer = {
      enable = true;
      config = {
        imports = [ deployment ];
        # The same stand-ins inside: the container seeds the slot's
        # profile with nix-env too.
        inherit (common.slotHost) nix;
        systemd.tmpfiles.rules = common.slotHost.systemd.tmpfiles.rules;
      };
    };
  };

  # A workstation NetworkManager runs: its LAN address is a NetworkManager
  # profile, the container's veth is left to the containers module.
  nodes.nm =
    { config, ... }:
    {
      imports = [ self.nixosModules.local-container ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
      environment.systemPackages = [ pkgs.curl ];

      networking.interfaces = lib.mkForce { eth1 = { }; };
      networking.networkmanager = {
        enable = true;
        settings.main.no-auto-default = "*";
        ensureProfiles.profiles.lan = {
          connection = {
            id = "lan";
            type = "ethernet";
            interface-name = "eth1";
          };
          ipv4 = {
            method = "manual";
            address1 = "${config.networking.primaryIPAddress}/24";
          };
          ipv6.method = "disabled";
        };
      };

      services.hyperhermes.localContainer = {
        enable = true;
        hostAddress = nmHostAddress;
        localAddress = nmLocalAddress;
        config = {
          imports = [ deployment ];
          services.hyperhermes.agents.alice.slot.enable = lib.mkForce false;
        };
      };
    };

  # Another machine on the host's LAN.
  nodes.peer = {
    virtualisation.memorySize = 512;
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript =
    { nodes, ... }:
    let
      guestHyper = nodes.machine.containers.${name}.config.services.hyperhermes;
      machineAddress = nodes.machine.networking.primaryIPAddress;
      nmAddress = nodes.nm.networking.primaryIPAddress;
      nmGuest = nodes.nm.containers.${name}.config;
    in
    assert lib.assertMsg (
      !nodes.nm.systemd.network.enable && nodes.nm.networking.networkmanager.enable
    ) "nm runs NetworkManager, not systemd-networkd";
    assert lib.assertMsg (
      nmGuest.networking.firewall.backend == "iptables"
    ) "nm's container runs the iptables firewall";
    ''
      def inside(cmd, timeout=900, host=machine):
          return host.succeed(f"nixos-container run ${name} -- {cmd}", timeout=timeout)

      def until_inside(cmd, timeout=300, host=machine):
          host.wait_until_succeeds(f"nixos-container run ${name} -- {cmd}", timeout=timeout)

      # Both hosts boot at once: the wait for the first covers the second.
      start_all()
      for host in (machine, nm):
          host.wait_for_unit("container@${name}.service")
          until_inside("systemctl is-active hyperhermes-local-secrets.service dex.service nginx.service hermes-dashboard-alice.service", host=host)
          until_inside("curl -sf -o /dev/null --unix-socket /run/oauth2-proxy-serve.sock http://localhost/ping", host=host)

      for host in (machine, nm):
          with subtest(f"{host.name}: the secrets from the first boot"):
              password = inside("cat /var/lib/hyperhermes-local/dex/alice.password", host=host).strip()
              assert len(password) == 24, password
              modes = inside(
                  "stat -c '%n %U %a' /var/lib/hyperhermes-local/dex/alice.password "
                  "/var/lib/hyperhermes-local/agents/alice /var/lib/hyperhermes-local/agents/alice/key "
                  "/var/lib/hyperhermes-local/agents/alice/key.pub",
                  host=host,
              )
              print(modes)
              assert "alice.password root 600" in modes and "agents/alice root 755" in modes, modes
              assert "key alice 400" in modes and "key.pub root 444" in modes, modes

          with subtest(f"{host.name}: alice signs in to her dashboard from the host"):
              host.wait_until_succeeds("curl -sf http://alice.${domain}:${toString port}/api/status", timeout=120)
              for mode in ("", "--native"):
                  print(host.succeed(
                      f"${python}/bin/python3 ${../local-sso/login.py} {mode} http://alice.${domain}:${toString port} "
                      f"alice@${domain} {password} hermes-alice"
                  ))

          with subtest(f"{host.name}: a port alice publishes, after her sign-in there"):
              inside(
                  "systemd-run --uid=alice --unit=echo -p RuntimeDirectory=echo "
                  "${pkgs.python3}/bin/python3 ${../publish/echo.py} ${toString alicePrivate} /run/echo/log",
                  host=host,
              )
              until_inside("curl -sf http://127.0.0.1:${toString alicePrivate}/", host=host)
              print(host.succeed(
                  f"${python}/bin/python3 ${../publish/serve.py} http://${toString alicePrivate}.alice.${domain}:${toString port}/ "
                  f"alice@${domain} {password} ok"
              ))

      with subtest("alice's slot: in by ssh, its port 80 at slot.alice"):
          # A login shell: the agent's PATH (core) has `slot`.
          inside("runuser -l alice -c 'slot start'")
          until_inside("runuser -l alice -c 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@${slot4} true'", timeout=180)
          inside("${slotHttp}")
          until_inside("curl -sf -m 5 -o /dev/null http://${slot4}/", timeout=60)
          out = machine.wait_until_succeeds("curl -sf -m 10 http://slot.alice.${domain}:${toString port}/", timeout=60)
          assert out.startswith("alice-http peer=10.43.1.1 "), out

      with subtest("slot info and the skill call the slot's IPv6 private"):
          info = inside("runuser -l alice -c 'slot info'")
          assert "private" in info and "(anywhere)" not in info and "public, all ports" not in info, info
          skill = machine.succeed(
              "for d in ${lib.concatStringsSep " " guestHyper.skillDirs}; do "
              "f=$d/container-slot/SKILL.md; if [ -f $f ]; then cat $f; fi; done"
          )
          assert "slot.<you>.${domain}:${toString port}" in skill, skill
          assert "IPv6 address is private" in skill, skill
          assert "public IPv6" not in skill and "From anywhere" not in skill, skill
          for placeholder in ["@summary@", "@egress@", "@v6reach@", "@reach@", "@website@"]:
              assert placeholder not in skill, skill

      for host, address, container in ((machine, "${machineAddress}", "${localAddress}"), (nm, "${nmAddress}", "${nmLocalAddress}")):
          with subtest(f"{host.name}: a LAN peer routed to the container reaches it, but not its web front"):
              peer.succeed(f"ip route add {container}/32 via {address}")
              peer.wait_until_succeeds(f"ping -c 1 -W 2 {container}", timeout=60)
              peer.fail(f"curl -s -m 5 -o /dev/null http://{container}:${toString port}/")
              # The host's forward still gets in.
              host.succeed("curl -sf -m 10 -o /dev/null http://alice.${domain}:${toString port}/api/status")

      with subtest("alice's key directory is root's; a link left in it leaks nothing"):
          k = "/var/lib/hyperhermes-local/agents/alice"
          target = "/var/lib/hyperhermes-local/dex/alice.hash"
          secret = inside(f"cat {target}").strip()
          assert secret, secret
          machine.fail(f"nixos-container run ${name} -- runuser -u alice -- ln -sfn {target} {k}/key.pub")
          machine.fail(f"nixos-container run ${name} -- runuser -u alice -- rm -f {k}/key.pub")
          # What the agent-owned directory of earlier versions let her leave:
          # key.pub a link to a file only root reads.
          inside("runuser -l alice -c 'slot stop'")
          inside(f"ln -sfn {target} {k}/key.pub")
          machine.fail("nixos-container run ${name} -- runuser -l alice -c 'slot start'")
          keys = inside("cat /run/container-slots/alice/authorized_keys")
          assert secret not in keys, keys
          inside("systemctl restart hyperhermes-local-secrets.service")
          modes = inside(f"stat -c '%n %U %a %F' {target} {k}/key.pub {k}/key")
          print(modes)
          assert f"{target} root 600 regular file" in modes, modes
          assert f"{k}/key.pub root 444 regular file" in modes, modes
          assert f"{k}/key alice 400 regular file" in modes, modes
          inside("runuser -l alice -c 'slot start'")
          until_inside("runuser -l alice -c 'ssh -o BatchMode=yes -o ConnectTimeout=5 root@${slot4} true'", timeout=180)
          keys = inside("cat /run/container-slots/alice/authorized_keys")
          assert secret not in keys and keys.startswith("ssh-ed25519 "), keys
    '';
}
