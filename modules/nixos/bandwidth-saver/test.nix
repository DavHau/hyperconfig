# ./default.nix in a VM: a laptop peered over yggdrasil with `edi` (the
# kept machine, reached as edi.wg-edi like the fleet's static peers) and
# `other` (dropped while saving), multicast on too. A wheel user flips
# the mode without a password (polkit), and:
#   - on: the listed system unit, its timer and the user unit stop and
#     stay stopped through a start (what a deploy's switch or a timer
#     does); yggdrasil keeps the same address with edi as its only peer,
#     and edi still reaches the laptop over the overlay;
#   - off: exactly those units run again, `other` peers again, and a unit
#     that was stopped before `on` stays stopped;
#   - a failed `on` (no kept peer comes up) falls back to the full mesh.
{ pkgs }:
let
  yggNode =
    { lib, ... }:
    {
      services.yggdrasil = {
        enable = true;
        persistentKeys = true;
        settings = {
          Listen = [ "tcp://[::]:6443" ];
          MulticastInterfaces = [
            {
              Regex = "eth1";
              Beacon = true;
              Listen = true;
              Port = 5400;
            }
          ];
        };
      };
      networking.firewall.allowedTCPPorts = [
        6443
        5400
      ];
      networking.firewall.allowedUDPPorts = [ 9001 ];
      environment.systemPackages = [ pkgs.jq ];
    };
in
pkgs.testers.runNixOSTest {
  name = "bandwidth-saver";

  nodes.edi = yggNode;
  nodes.other = yggNode;

  nodes.laptop =
    { config, lib, nodes, ... }:
    {
      imports = [
        ./default.nix
        yggNode
      ];
      networking.hosts.${nodes.edi.networking.primaryIPAddress} = [ "edi.wg-edi" ];
      networking.hosts.${nodes.other.networking.primaryIPAddress} = [ "other.wg-edi" ];
      services.yggdrasil.settings.Peers = [
        "tcp://edi.wg-edi:6443"
        "tcp://other.wg-edi:6443"
      ];
      services.zerotierone.enable = false;

      hyper.bandwidthSaver = {
        enable = true;
        systemUnits = [
          "chatty.service"
          "idle.service"
          "missing.service"
        ];
        userUnits = [ "poller.service" ];
        containerUnits = { };
        yggdrasil.upTimeout = 30;
      };

      systemd.services.chatty = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        serviceConfig.Restart = "always";
      };
      systemd.timers.chatty = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnUnitActiveSec = "1h";
      };
      # Listed but not running at `on`: must not be started by `off`.
      systemd.services.idle.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";

      systemd.user.services.poller = {
        wantedBy = [ "default.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };

      users.users.alice = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        linger = true;
      };
    };

  testScript = ''
    import json

    start_all()
    for m in (edi, other, laptop):
        m.wait_for_unit("yggdrasil.service")
    laptop.wait_for_unit("chatty.service")
    laptop.wait_for_unit("user@1000.service")
    laptop.wait_until_succeeds("systemctl --user -M alice@ is-active poller.service")

    def peers(m):
        out = json.loads(m.succeed("yggdrasilctl -json getPeers"))
        return {p["key"] for p in out["peers"] if p["up"]}

    def key(m):
        return json.loads(m.succeed("yggdrasilctl -json getSelf"))["key"]

    def addr(m):
        return json.loads(m.succeed("yggdrasilctl -json getSelf"))["address"]

    edi_key, other_key = key(edi), key(other)
    laptop_addr = addr(laptop)
    laptop.wait_until_succeeds(
        "yggdrasilctl -json getPeers | jq -e '[.peers[] | select(.up)] | length >= 2'", timeout=60)
    assert {edi_key, other_key} <= peers(laptop), peers(laptop)

    with subtest("wheel user turns it on without a password"):
        laptop.succeed("su - alice -c 'systemctl start bandwidth-saver.service'")
        laptop.succeed("systemctl is-active bandwidth-saver.service")
        status = laptop.succeed("su - alice -c 'bandwidth-saver status'")
        print(status)
        assert "ON" in status and "chatty.service" in status and "poller.service" in status, status
        bar = json.loads(laptop.succeed("su - alice -c 'bandwidth-saver bar'"))
        assert bar["icon"] == "leaf" and "chatty.service" in bar["tooltip"], bar

    with subtest("listed units are stopped and stay stopped"):
        laptop.fail("systemctl is-active chatty.service")
        laptop.fail("systemctl is-active chatty.timer")
        laptop.fail("systemctl --user -M alice@ is-active poller.service")
        # What a switch or a timer does: start them. The guard holds.
        laptop.succeed("systemctl start chatty.service chatty.timer multi-user.target")
        laptop.succeed("systemctl --user -M alice@ start poller.service")
        laptop.fail("systemctl is-active chatty.service")
        laptop.fail("systemctl is-active chatty.timer")
        laptop.fail("systemctl --user -M alice@ is-active poller.service")

    with subtest("yggdrasil keeps its address with edi as the only peer"):
        assert addr(laptop) == laptop_addr
        assert peers(laptop) == {edi_key}, peers(laptop)
        # other's static peering and multicast would come back inbound
        # within seconds if the listener or beacons were still on.
        laptop.succeed("sleep 1; sleep 1; sleep 1; sleep 1; sleep 1; sleep 1; sleep 1; sleep 1")
        assert peers(laptop) == {edi_key}, peers(laptop)
        edi.succeed(f"ping -6 -c1 -W5 {laptop_addr}")

    with subtest("off restores exactly what on stopped"):
        laptop.succeed("su - alice -c 'bandwidth-saver off'")
        laptop.wait_for_unit("chatty.service")
        laptop.succeed("systemctl is-active chatty.timer")
        laptop.wait_until_succeeds("systemctl --user -M alice@ is-active poller.service")
        laptop.fail("systemctl is-active idle.service")
        laptop.wait_until_succeeds(
            "yggdrasilctl -json getPeers | jq -e '[.peers[] | select(.up)] | length >= 2'", timeout=60)
        assert other_key in peers(laptop)
        laptop.succeed("test ! -e /run/bandwidth-saver")
        laptop.succeed("test -z \"$(ls /run/systemd/system.control/ 2>/dev/null)\"")
        assert "off" in laptop.succeed("bandwidth-saver status")

    with subtest("kept peer lost later: the check falls back to the full mesh"):
        laptop.succeed("bandwidth-saver on")
        assert peers(laptop) == {edi_key}, peers(laptop)
        edi.succeed("systemctl stop yggdrasil.service")
        laptop.wait_until_fails(
            "yggdrasilctl -json getPeers | jq -e '[.peers[] | select(.up)] | length > 0'", timeout=60)
        for _ in range(3):
            laptop.succeed("systemctl start bandwidth-saver-ygg-check.service")
        laptop.succeed("test ! -e /run/bandwidth-saver/yggdrasil")
        laptop.wait_until_succeeds(f"yggdrasilctl -json getPeers | jq -e '.peers[] | select(.up and .key == \"{other_key}\")'", timeout=60)
        laptop.fail("systemctl is-active chatty.service")
        laptop.succeed("bandwidth-saver off")
        laptop.wait_for_unit("chatty.service")

    with subtest("no kept peer up: falls back to the full mesh"):
        edi.succeed("systemctl stop yggdrasil.service")
        laptop.succeed("bandwidth-saver on")
        laptop.wait_until_succeeds(
            "journalctl -u bandwidth-saver | grep -q 'back to the full mesh'", timeout=60)
        laptop.wait_until_succeeds(f"yggdrasilctl -json getPeers | jq -e '.peers[] | select(.up and .key == \"{other_key}\")'", timeout=60)
        # The units are still held; off restores them.
        laptop.fail("systemctl is-active chatty.service")
        laptop.succeed("bandwidth-saver off")
        laptop.wait_for_unit("chatty.service")
  '';
}
