# nixosModules.local-container end to end, with the example's own
# container config (../../example/hermes.nix: alice, with a slot). Every
# check runs from the HOST, as a browser on the workstation would:
# - the secrets exist after the container's first boot, alice's dex
#   password among them,
# - alice signs in to her dashboard at dex (browser and app sign-in) and
#   ends on authenticated dashboard API calls,
# - an app alice publishes on her first private port answers at
#   http://30010.alice.hermes.localhost:8473/ after her sign-in there,
# - alice starts her slot (a container inside the container) and gets in
#   by ssh; its port 80 answers at http://slot.alice.hermes.localhost:8473/,
# - `slot info` and the skill call the slot's IPv6 private,
# - a peer on the host's LAN routing to the container's address reaches
#   it (ping), but not its web front,
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
        imports = [ ../../example/hermes.nix ];
        # The agents' venv is not under test.
        services.hyperhermes.pythonPackages = _: [ ];
        environment.systemPackages = [ pkgs.curl ];
        # The same stand-ins inside: the container seeds the slot's
        # profile with nix-env too.
        inherit (common.slotHost) nix;
        systemd.tmpfiles.rules = common.slotHost.systemd.tmpfiles.rules;
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
    in
    ''
      def inside(cmd, timeout=900):
          return machine.succeed(f"nixos-container run ${name} -- {cmd}", timeout=timeout)

      def until_inside(cmd, timeout=300):
          machine.wait_until_succeeds(f"nixos-container run ${name} -- {cmd}", timeout=timeout)

      start_all()
      machine.wait_for_unit("container@${name}.service")
      until_inside("systemctl is-active hyperhermes-local-secrets.service dex.service nginx.service hermes-dashboard-alice.service")
      until_inside("curl -sf -o /dev/null --unix-socket /run/oauth2-proxy-serve.sock http://localhost/ping")

      with subtest("the secrets from the first boot"):
          password = inside("cat /var/lib/hyperhermes-local/dex/alice.password").strip()
          assert len(password) == 24, password
          modes = inside(
              "stat -c '%n %U %a' /var/lib/hyperhermes-local/dex/alice.password "
              "/var/lib/hyperhermes-local/agents/alice /var/lib/hyperhermes-local/agents/alice/key "
              "/var/lib/hyperhermes-local/agents/alice/key.pub"
          )
          print(modes)
          assert "alice.password root 600" in modes and "agents/alice root 755" in modes, modes
          assert "key alice 400" in modes and "key.pub root 444" in modes, modes

      with subtest("alice signs in to her dashboard from the host"):
          machine.wait_until_succeeds("curl -sf http://alice.${domain}:${toString port}/api/status", timeout=120)
          for mode in ("", "--native"):
              print(machine.succeed(
                  f"${python}/bin/python3 ${../local-sso/login.py} {mode} http://alice.${domain}:${toString port} "
                  f"alice@${domain} {password} hermes-alice"
              ))

      with subtest("a port alice publishes, after her sign-in there"):
          inside(
              "systemd-run --uid=alice --unit=echo -p RuntimeDirectory=echo "
              "${pkgs.python3}/bin/python3 ${../publish/echo.py} ${toString alicePrivate} /run/echo/log"
          )
          until_inside("curl -sf http://127.0.0.1:${toString alicePrivate}/")
          print(machine.succeed(
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

      with subtest("a LAN peer routed to the container reaches it, but not its web front"):
          peer.succeed("ip route add ${localAddress}/32 via ${machineAddress}")
          peer.wait_until_succeeds("ping -c 1 -W 2 ${localAddress}", timeout=60)
          peer.fail("curl -s -m 5 -o /dev/null http://${localAddress}:${toString port}/")
          # The host's forward still gets in.
          machine.succeed("curl -sf -m 10 -o /dev/null http://alice.${domain}:${toString port}/api/status")

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
