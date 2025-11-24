{
  lib,
  config,
  ...
}:

let
  machines = [
    "controller1"
    "controller2"
    "peer1"
    "peer2"
    "peer3"
    # external machine for external peer testing
    "external1"
  ];

  controllerPrefix =
    controllerName:
    builtins.readFile (
      config.clan.directory
      + "/vars/per-machine/${controllerName}/wireguard-network-wg-test-one/prefix/value"
    );
  peerSuffix =
    peerName:
    builtins.readFile (
      config.clan.directory + "/vars/per-machine/${peerName}/wireguard-network-wg-test-one/suffix/value"
    );
  # external peer suffixes are stored via shared vars
  externalPeerSuffix =
    externalName:
    builtins.readFile (
      config.clan.directory
      + "/vars/shared/wireguard-network-wg-test-one-external-peer-${externalName}/suffix/value"
    );
in
{
  name = "wireguard";

  clan = {
    directory = ./.;
    inventory = {

      machines = lib.genAttrs machines (_: { });

      instances = {

        /*
                        wg-test-one
          ┌───────────────────────────────┐
          │            ◄─────────────     │
          │ controller2              controller1
          │    ▲       ─────────────►    ▲     ▲
          │    │ │ │ │                 │ │   │ │
          │    │ │ │ │                 │ │   │ │
          │    │ │ │ │                 │ │   │ │
          │    │ │ │ └───────────────┐ │ │   │ │
          │    │ │ └──────────────┐  │ │ │   │ │
          │      ▼                │  ▼ ▼     ▼
          └─► peer2               │  peer1  peer3
                                  │          ▲
                                  └──────────┘
        */

        wg-test-one = {

          module.name = "@clan/wireguard";
          module.input = "self";

          roles.controller.machines."controller1".settings = {
            endpoint = "192.168.1.1";
            # Enable IPv4 for external peers
            ipv4.enable = true;
            ipv4.address = "10.42.1.1/24";
            # add an external peer to controller1 with IPv4
            externalPeers.external1 = {
              ipv4.address = "10.42.1.50/32";
            };
          };

          roles.controller.machines."controller2".settings = {
            endpoint = "192.168.1.2";
            # add the same external peer to controller2 to test multi-controller connection
            externalPeers.external1 = { };
          };

          roles.peer.machines = {
            peer1.settings.controller = "controller1";
            peer2.settings.controller = "controller2";
            peer3.settings.controller = "controller1";
          };
        };

        # TODO: Will this actually work with conflicting ports? Can we re-use interfaces?
        #wg-test-two = {
        #  module.name = "@clan/wireguard";

        #  roles.controller.machines."controller1".settings = {
        #    endpoint = "192.168.1.1";
        #    port = 51922;
        #  };

        #  roles.peer.machines = {
        #    peer1 = { };
        #  };
        #};
      };
    };
  };

  nodes.external1 =
    let
      controller1Prefix = controllerPrefix "controller1";
      controller2Prefix = controllerPrefix "controller2";
      external1Suffix = externalPeerSuffix "external1";
    in
    {
      networking.extraHosts = ''
        ${controller1Prefix}::1 controller1.wg-test-one
        ${controller2Prefix}::1 controller2.wg-test-one
      '';
      networking.wireguard.interfaces."wg0" = {

        # Multiple IPs, one in each controller's subnet (IPv6) plus IPv4
        ips = [
          "${controller1Prefix + ":" + external1Suffix}/56"
          "${controller2Prefix + ":" + external1Suffix}/56"
          "10.42.1.50/32" # IPv4 address for controller1
        ];

        privateKeyFile =
          builtins.toFile "wg-priv-key"
            # This needs to be updated whenever update-vars was executed
            # Get the value from the generated vars via this command:
            #   echo "AGE-SECRET-KEY-1PL0M9CWRCG3PZ9DXRTTLMCVD57U6JDFE8K7DNVQ35F4JENZ6G3MQ0RQLRV" | SOPS_AGE_KEY_FILE=/dev/stdin nix run nixpkgs#sops decrypt clanServices/wireguard/tests/vm/vars/shared/wireguard-network-wg-test-one-external-peer-external1/privatekey/secret
            "wO8dl3JWgV5J+0D/2UDcLsxTD25IWTvd5ed6vv2Nikk=";

        # Connect to both controllers
        peers = [
          # Controller 1
          {
            publicKey = (
              builtins.readFile (
                config.clan.directory + "/vars/per-machine/controller1/wireguard-keys-wg-test-one/publickey/value"
              )
            );

            # Allow controller1's /56 subnet (IPv6) and IPv4 subnet
            allowedIPs = [
              "${controller1Prefix}::/56"
              "10.42.1.0/24" # IPv4 subnet for internet access
            ];

            endpoint = "controller1:51820";

            persistentKeepalive = 25;
          }
          # Controller 2
          {
            publicKey = (
              builtins.readFile (
                config.clan.directory + "/vars/per-machine/controller2/wireguard-keys-wg-test-one/publickey/value"
              )
            );

            # Allow controller2's /56 subnet
            allowedIPs = [ "${controller2Prefix}::/56" ];

            endpoint = "controller2:51820";

            persistentKeepalive = 25;
          }
        ];
      };
    };

  testScript = ''
    start_all()

    # Start network on all machines including external1
    machines = [peer1, peer2, peer3, controller1, controller2, external1]
    for m in machines:
        m.systemctl("start network-online.target")

    for m in machines:
        m.wait_for_unit("network-online.target")
        m.wait_for_unit("systemd-networkd.service")

    print("\n\n" + "="*60)
    print("STARTING PING TESTS")
    print("="*60)

    # Test mesh connectivity between regular clan machines
    clan_machines = [peer1, peer2, peer3, controller1, controller2]
    for m1 in clan_machines:
        for m2 in clan_machines:
            if m1 != m2:
                print(f"\n--- Pinging from {m1.name} to {m2.name}.wg-test-one ---")
                m1.wait_until_succeeds(f"ping -c1 {m2.name}.wg-test-one >&2")

    # Test that external peer can reach both controllers (multi-controller connection)
    print("\n--- Testing external1 -> controller1 (direct connection) ---")
    external1.wait_until_succeeds("ping -c1 controller1.wg-test-one >&2")

    print("\n--- Testing external1 -> controller2 (direct connection) ---")
    external1.wait_until_succeeds("ping -c1 controller2.wg-test-one >&2")

    # Test IPv4 connectivity
    print("\n--- Testing external1 -> controller1 (IPv4) ---")
    external1.wait_until_succeeds("ping -c1 10.42.1.1 >&2")

    # Test that all clan machines can reach the external peer
    for m in clan_machines:
        print(f"\n--- Pinging from {m.name} to external1.wg-test-one ---")
        m.wait_until_succeeds("ping -c1 external1.wg-test-one >&2")

    # Test that external peer can reach a regular peer via controller1
    print("\n--- Testing external1 -> peer1 (via controller1) ---")
    external1.wait_until_succeeds("ping -c1 ${controllerPrefix "controller1"}:${peerSuffix "peer1"} >&2")

    # Test controller failover
    print("\n--- Shutting down controller1 ---")
    controller1.shutdown()
    print("\n--- Testing external1 -> peer1 (via controller2 after controller1 shutdown) ---")
    external1.wait_until_succeeds("ping -c1 ${controllerPrefix "controller2"}:${peerSuffix "peer1"} >&2")

  '';
}
