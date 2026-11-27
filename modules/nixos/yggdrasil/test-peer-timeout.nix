# ./default.nix's `hyper.yggdrasil.peerTimeout` in VMs: two nodes peered
# over one link that netem turns into a roaming laptop's weak Wi-Fi, as
# measured on amy: ~700 ms RTT (350 ms each way, jitter), 5 % loss each
# way, and the radio's short dropouts (beacon loss): three times, 6 s of
# total loss while traffic is sent, then the weak link again.
#   - with the fleet default (15 s) the peering outlives every dropout
#     (no disconnect) and traffic resumes after each;
#   - control: the same link with upstream's 3 s (PeerTimeout removed on
#     both ends) tears the peering down at the dropouts.
{ pkgs }:
let
  inherit (pkgs) lib;
  # Throwaway yggdrasil keys for the test only (the same as ./test.nix).
  keys = {
    a = {
      key = "7e02b4bd114cc99182410f7e44079feb9e5320f94bd6bbfaa19c6d55614988d688a3fc4d84d0efb7354e33d126ab8dccb5b19605c273f7e2748b706e51f13722";
      addr = "200:eeb8:764:f65e:2091:9563:985d:b2a8";
    };
    b = {
      key = "dcf30ecf5e2f1f1e2e39f206eb0e12585012ffacbfaf25d54e9ee49360f8ab904fa36751729d6cbda2bc2b86a3d4498e69d472cfa78681c18e431005a00a9e55";
      addr = "201:c172:62ba:358a:4d09:750f:51e5:70ae";
    };
  };
  pem =
    name:
    pkgs.runCommand "ygg-test-key-${name}" { } ''
      echo '{"PrivateKey":"${keys.${name}.key}"}' > conf.json
      ${pkgs.yggdrasil}/bin/yggdrasil -useconffile conf.json -exportkey > $out
    '';

  node =
    name: peers:
    { config, ... }:
    {
      imports = [ ./default.nix ];
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.firewall.allowedTCPPorts = [ 7000 ];
      environment.systemPackages = [
        config.services.yggdrasil.package
        pkgs.iproute2
        pkgs.jq
      ];
      boot.kernelModules = [ "sch_netem" ];
      services.yggdrasil = {
        enable = true;
        settings = {
          PrivateKeyPath = pem name;
          Listen = [ "tcp://[::]:7000" ];
          Peers = peers;
          MulticastInterfaces = [ ];
          IfName = "ygg";
        };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "yggdrasil-peer-timeout";
  globalTimeout = 900;

  nodes.a = node "a" [ "tcp://192.168.1.2:7000" ];
  nodes.b = node "b" [ ];

  testScript = ''
    A, B = "${keys.a.addr}", "${keys.b.addr}"
    start_all()
    for m in (a, b):
        m.wait_for_unit("yggdrasil.service")

    with subtest("the fleet default is applied"):
        for m in (a, b):
            m.succeed("journalctl -u yggdrasil | grep -q 'Peer timeout: 15s'")
        a.wait_until_succeeds(f"ping -6 -c1 -W2 {B}", timeout=60)

    WEAK = "delay 350ms 50ms loss 5%"
    for m in (a, b):
        m.succeed(f"tc qdisc replace dev eth1 root netem {WEAK}")

    def disconnects(m):
        inv = m.succeed("systemctl show -p InvocationID --value yggdrasil").strip()
        return m.succeed(f"journalctl _SYSTEMD_INVOCATION_ID={inv} -o cat | grep Disconnected || true").strip().splitlines()

    def weak_window(label):
        """Three dropouts on the weak link, with traffic; a's disconnects and
        whether traffic came back after each dropout."""
        before = len(disconnects(a))
        resumed = []
        for _ in range(3):
            # 8 s of traffic on the weak link
            a.execute(f"ping -6 -q -i 0.5 -w 8 {B}")
            # 6 s dropout, traffic still sent (it arms the read deadline)
            for m in (a, b):
                m.succeed("tc qdisc change dev eth1 root netem delay 350ms loss 100%")
            a.execute(f"ping -6 -q -i 0.5 -w 6 {B}")
            for m in (a, b):
                m.succeed(f"tc qdisc change dev eth1 root netem {WEAK}")
            # traffic again within 15 s (TCP's next retransmission)
            rc, _ = a.execute(f"ping -6 -q -i 0.5 -w 15 -c 1 {B}")
            resumed.append(rc == 0)
        new = disconnects(a)[before:]
        print(f"{label}: {len(new)} disconnects, traffic resumed after each dropout: {resumed}")
        print("\n".join(new))
        return len(new), resumed

    with subtest("15 s: the peering outlives the dropouts"):
        n15, resumed = weak_window("15s")
        assert n15 == 0, n15
        assert all(resumed), resumed

    with subtest("control: upstream's 3 s drops the peering on the same link"):
        for m in (a, b):
            conf = m.succeed("grep -o '/nix/store/[^ ]*-yggdrasil.conf' $(systemctl show -p ExecStart --value yggdrasil | grep -o '/nix/store/[^ ;]*' | head -1)").strip()
            m.succeed(
                f"jq 'del(.PeerTimeout)' {conf} > /run/ygg-3s.conf",
                "chmod 644 /run/ygg-3s.conf",
                "mkdir -p /run/systemd/system/yggdrasil.service.d",
                "printf '[Service]\\nExecStart=\\nExecStart=%s -useconffile /run/ygg-3s.conf\\n' "
                "$(readlink -f $(command -v yggdrasil)) > /run/systemd/system/yggdrasil.service.d/3s.conf",
                "systemctl daemon-reload",
                "systemctl restart yggdrasil",
            )
        for m in (a, b):
            m.wait_for_unit("yggdrasil.service")
            m.fail("journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value yggdrasil) | grep -q 'Peer timeout'")
        a.wait_until_succeeds(f"ping -6 -c1 -W5 {B}", timeout=120)
        n3, _ = weak_window("3s")
        assert n3 >= 2, n3
  '';
}
