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
#   by ssh; its port 80 answers at http://slot.alice.hermes.localhost:8473/.
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

  testScript = ''
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
        modes = inside("stat -c '%n %U %a' /var/lib/hyperhermes-local/dex/alice.password /var/lib/hyperhermes-local/agents/alice/key")
        print(modes)
        assert "alice.password root 600" in modes and "key alice 400" in modes, modes

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
  '';
}
