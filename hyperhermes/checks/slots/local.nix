# Agent slots (../../modules/slots) with the local exposure: one host, no
# public IPv4, no DNS, no egress tunnel. alice has a slot, bob (another
# account on the host) has none. Covered: alice starts her slot and gets in
# by ssh; `slot info` and the container-slot skill name the local URL and
# nothing public; http://slot.alice.hermes.localhost:8473/ reaches the
# slot's port 80 through the local web front for anyone on the host (Host
# kept, the proxy hop 10.43.4.1 as the peer), while bob still cannot reach
# the slot's internal v4 himself; none of the public-mode pieces (SNI
# router, public IPv4 ports) exist; a host file declared as a slot
# credential shows up in the slot as a system credential.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  common = import ./common.nix { inherit pkgs; };
  inherit (common) sshKeys responder;
  prefix = "2001:db8:1:2";
  alice4 = "10.43.4.2";
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-slots-local";
  globalTimeout = 900;

  nodes.host =
    { config, ... }:
    {
      imports = [
        common.agentsStub
        common.slotHost
        self.nixosModules.exposure
        self.nixosModules.slots
      ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.vlans = [ 1 ];

      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      systemd.network.networks."40-br0".address = [
        "192.0.2.2/24"
        "${prefix}::2/64"
      ];
      services.container-slots = {
        enable = true;
        uplink = "eth1";
        uplinkMac = common.uplinkMacOf config;
        lanIPv4 = "192.0.2.0/24";
        ipv6Prefix = prefix;
        deployKeys = [ common.adminKey ];
      };
      # A secret outside the store, root-only, as a clan var would be.
      systemd.tmpfiles.rules = [ "f+ /var/lib/slot-test-cred 0400 root root - alice-secret" ];
      services.container-slots.slots.alice.credentials.test-cred = "/var/lib/slot-test-cred";

      services.hyperhermes = {
        exposure.enable = true;
        agents.alice = {
          uid = 1000;
          sshKeyFile = "/etc/agent-keys/alice";
          slot = {
            enable = true;
            id = 4;
            deployKey = sshKeys.alice.pub;
          };
        };
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
      users.users.bob = {
        isNormalUser = true;
        uid = 1001;
      };
      environment.etc."agent-keys/alice" = {
        text = sshKeys.alice.priv;
        mode = "0600";
        user = "alice";
      };

      # the agents' tools (hyperhermes puts them on the agents' PATH;
      # here system-wide, so runuser finds them)
      environment.systemPackages = config.services.hyperhermes.extraPackages ++ [
        pkgs.curl
        pkgs.netcat-openbsd
      ];
    };

  testScript =
    { nodes, ... }:
    let
      skillDir = lib.head nodes.host.services.hyperhermes.skillDirs;
    in
    ''
      in_slot = "${pkgs.util-linux}/bin/nsenter -t $(machinectl show alice -p Leader --value) "
      url = "http://slot.alice.hermes.localhost:8473/"

      start_all()
      host.wait_for_unit("multi-user.target")
      host.wait_for_unit("nginx.service")

      with subtest("the agent starts its slot and gets in"):
          host.succeed("runuser -u alice -- slot start")
          host.wait_until_succeeds("runuser -u alice -- ssh -o BatchMode=yes -o ConnectTimeout=5 root@${alice4} true", timeout=90)

      with subtest("a declared credential reaches the slot as a system credential"):
          cred = host.succeed(in_slot + "-a ${pkgs.coreutils}/bin/cat /run/credentials/@system/test-cred")
          assert cred == "alice-secret", repr(cred)

      with subtest("slot info and the skill name the local URL, nothing public"):
          info = host.succeed("runuser -u alice -- slot info")
          assert url in info, info
          assert "tcp ports" not in info and "hostname:" not in info, info
          skill = host.succeed("cat ${skillDir}/container-slot/SKILL.md")
          assert "slot.<you>.hermes.localhost:8473" in skill, skill
          assert "public IPv4 (`slot info`)" not in skill, skill
          for placeholder in ["@summary@", "@egress@", "@v6reach@", "@reach@", "@website@"]:
              assert placeholder not in skill, skill

      with subtest("the local web front reaches the slot's port 80"):
          host.succeed(in_slot + "-n ${pkgs.nftables}/bin/nft flush ruleset")
          host.succeed(f"systemd-run --unit=a-http {in_slot}-a ${pkgs.socat}/bin/socat TCP-LISTEN:80,fork,reuseaddr EXEC:'${responder} alice-http'")
          host.wait_until_succeeds("nc -z -w 5 ${alice4} 80", timeout=30)
          out = host.succeed(f"runuser -u bob -- curl -s -m 10 {url}")
          assert out.startswith("alice-http peer=10.43.4.1 xff="), out
          # bob has no way in but the web front
          host.fail("runuser -u bob -- curl -s -m 5 http://${alice4}/")
          host.succeed("systemctl stop a-http")

      with subtest("no public-mode pieces"):
          assert "prerouting" not in host.succeed("nft list table inet agent-slots")
          host.fail("ss -ltn | grep -q ':444 '")
          assert "dnat" not in host.succeed("nft list table inet container-slots")
    '';
}
