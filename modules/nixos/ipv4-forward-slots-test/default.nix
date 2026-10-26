# ../ipv4-forward.nix with a container slot behind it (hyperhermes'
# nixosModules.container-slots), set up as on som: `gateway` runs the real
# gateway role on 38.89.142.76 (sgp), `som` the backend role with one
# isolated slot that takes a port of the public IPv4 and sends its own
# connections out an egress link (the stand-in for wg-mullvad), and `client`
# plays the internet on vlan 1 and the egress relay on vlan 2, which accepts
# only the tunnel's own source address, as a relay does. Covered: a
# connection to the public IPv4 reaches the slot with the client's address
# and its replies go back through wg-v4fwd (the return mark), not out the
# uplink, where the client would never match them; the slot's own
# connections still leave through the egress link; the return mark leaves
# the Mullvad app's mark alone.
{
  pkgs,
  hyperhermes,
}:
let
  inherit (pkgs) lib;

  # Test-only keys; ./vars holds their public halves.
  wgKeys = {
    sgp = "UGJQE4KIqVRoTnfJ4X6YiJNvMt1Vcock2T3t+Vu2vkg=";
    som = "iI9wf7ORSTshbaYsdF62m0yhoi3wRA7v8CpAIWaRxHk=";
  };

  publicIPv4 = "38.89.142.76";
  clientIPv4 = "38.89.142.10";
  somIPv4 = "38.89.142.2";
  # the egress link (wg-mullvad on som): som's end, the relay's end
  tunnelIPv4 = "10.64.0.2";
  relayIPv4 = "10.64.0.1";
  egressTable = 51830;
  # the slot: isolated, one port of the public IPv4
  slotId = 4;
  slotIPv4 = "10.43.${toString slotId}.2";
  slotPort = 14043;

  # What clan provides to ../ipv4-forward.nix: the generator declarations
  # (ignored here), each file's deployed path, and the repo directory the
  # peer's public key is read from.
  clanStub =
    { lib, ... }:
    {
      options.clan.core.settings.directory = lib.mkOption { type = lib.types.path; };
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
      config.clan.core.settings.directory = ./.;
    };

  wgNode = machine: {
    imports = [
      clanStub
      ../ipv4-forward.nix
    ];
    environment.etc."test-vars/ipv4-forward-wg/privateKey" = {
      text = wgKeys.${machine};
      mode = "0640";
      group = "systemd-network";
    };
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.wait-online.enable = false;
  };

  # Answers one HTTP request with its tag and the peer it saw (socat sets
  # SOCAT_PEERADDR).
  responder = pkgs.writeShellScript "responder" ''
    while IFS= read -r line; do
      line=''${line%$'\r'}
      [ -z "$line" ] && break
    done
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n%s peer=%s\n' "$1" "$SOCAT_PEERADDR"
  '';

  # `nix-env -p <profile> --set <path>` as symlinks: <profile>-<n>-link to
  # the path, <profile> to the newest link (see som's nix.package).
  profileSet = pkgs.writeShellScript "nix-env" ''
    if [ "$#" -ne 4 ] || [ "$1" != -p ] || [ "$3" != --set ]; then
      echo "nix-env stand-in: only -p <profile> --set <path>" >&2
      exit 1
    fi
    p=$2
    n=1
    while [ -e "$p-$n-link" ] || [ -L "$p-$n-link" ]; do n=$((n + 1)); done
    ${pkgs.coreutils}/bin/ln -s "$4" "$p-$n-link"
    ${pkgs.coreutils}/bin/ln -sfn "$(${pkgs.coreutils}/bin/basename "$p")-$n-link" "$p"
  '';
in
pkgs.testers.runNixOSTest {
  name = "ipv4-forward-slots";
  globalTimeout = 900;

  nodes.client = {
    virtualisation.vlans = [
      1
      2
    ];
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = clientIPv4;
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
      {
        address = relayIPv4;
        prefixLength = 24;
      }
    ];
    networking.firewall.enable = false;
    # The relay end: only the tunnel's own address gets in, so anything som
    # sends down the tunnel unmasqueraded is lost, as it would be at Mullvad.
    networking.nftables.enable = true;
    networking.nftables.tables.relay = {
      family = "inet";
      content = ''
        chain input {
          type filter hook input priority filter; policy accept;
          iifname "eth2" ip saddr != ${tunnelIPv4} drop
        }
      '';
    };
    # tells each caller the address it came from
    systemd.services.peer4 = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP4-LISTEN:8081,fork,reuseaddr EXEC:'${responder} client'";
    };
    environment.systemPackages = [ pkgs.curl ];
  };

  nodes.gateway = {
    imports = [ (wgNode "sgp") ];
    hyper.ipv4Forward.role = "gateway";
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        address = publicIPv4;
        prefixLength = 24;
      }
    ];
  };

  nodes.som =
    { config, ... }:
    {
      imports = [
        (wgNode "som")
        hyperhermes.nixosModules.container-slots
      ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      virtualisation.vlans = [
        1
        2
      ];

      hyper.ipv4Forward.role = "backend";

      # The egress link, as ../mullvad-egress/egress.nix sets up wg-mullvad:
      # its own table with a default route, loose reverse-path checks.
      networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
        {
          address = tunnelIPv4;
          prefixLength = 24;
        }
      ];
      systemd.network.networks."40-eth2".routes = [
        {
          Gateway = relayIPv4;
          Table = egressTable;
        }
      ];
      boot.kernel.sysctl."net.ipv4.conf.eth2.rp_filter" = 2;
      networking.firewall.extraReversePathFilterRules = ''
        iifname "eth2" accept
      '';
      # As on som (../vpn.nix): isolatedEgress needs a loose rpfilter.
      networking.firewall.checkReversePath = "loose";

      # nspawn idmaps /nix/store into a slot with its own user namespace;
      # neither the host's virtiofs share nor the writable overlay on it
      # allows that, a read-only store image (erofs) does (on som: zfs).
      virtualisation.useNixStoreImage = true;
      virtualisation.writableStore = false;
      # nix cannot open that store at all (LocalStore creates
      # /nix/store/.links even in read-only mode), so the seed's
      # `nix-env -p <profile> --set <system>` gets a stand-in that writes
      # the same generation symlinks; on som the real one runs.
      nix.package = pkgs.symlinkJoin {
        inherit (pkgs.nix) pname version;
        passthru = pkgs.nix.passthru;
        paths = [ pkgs.nix ];
        postBuild = ''
          rm $out/bin/nix-env
          cp ${profileSet} $out/bin/nix-env
        '';
      };
      # nspawn binds the db into every slot; nothing here ever opens it.
      systemd.tmpfiles.rules = [ "d /nix/var/nix/db 0755 root root -" ];

      # The uplink becomes a port of br0, which carries the address. It is
      # on-link with the client: a reply that left this way would reach the
      # client from the tunnel address, which it never talked to.
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.ipv6.addresses = lib.mkForce [ ];
      systemd.network.networks."40-br0".address = [ "${somIPv4}/24" ];
      services.container-slots = {
        enable = true;
        uplink = "eth1";
        # the test driver's MAC for this node on vlan 1
        uplinkMac = "52:54:00:12:01:${
          lib.fixedWidthString 2 "0" (lib.toHexString config.virtualisation.test.nodeNumber)
        }";
        # som's home LAN, absent here
        lanIPv4 = "192.168.8.0/24";
        ipv6Prefix = "2001:db8:1:2";
        deployKeys = [ ];
        # as on som (machines/som/configuration.nix)
        foreignMarks.ipv4-forward = config.hyper.ipv4Forward.returnMark;
        publicIPv4Interface = "wg-v4fwd";
        isolatedEgress = {
          interface = "eth2";
          table = egressTable;
        };
        slots.web = {
          id = slotId;
          mode = "isolated";
          publicIPv4Ports = [ slotPort ];
        };
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.netcat-openbsd
      ];
    };

  testScript =
    { nodes, ... }:
    let
      returnMark = nodes.som.hyper.ipv4Forward.returnMark;
      mark = toString returnMark;
      markHex = "0x${lib.toLower (lib.toHexString returnMark)}";
    in
    ''
      in_slot = "${pkgs.util-linux}/bin/nsenter -t $(machinectl show web -p Leader --value) -a "
      public = "http://${publicIPv4}:${toString slotPort}/"

      start_all()
      som.wait_for_unit("container@web.service")
      client.wait_for_unit("peer4.service")
      som.wait_until_succeeds("ping -c1 -W1 10.99.0.1", timeout=60)
      # the guest's firewall is the guest's business: open it
      som.succeed(in_slot + "-n ${pkgs.nftables}/bin/nft flush ruleset")
      som.succeed(f"systemd-run --unit=web-port {in_slot}${pkgs.socat}/bin/socat TCP-LISTEN:${toString slotPort},fork,reuseaddr EXEC:'${responder} web'")
      som.wait_until_succeeds("nc -z -w 5 ${slotIPv4} ${toString slotPort}", timeout=30)

      with subtest("the public IPv4 reaches the slot and answers through the tunnel"):
          client.wait_until_succeeds(f"curl -s -m 10 {public} | grep -qx 'web peer=${clientIPv4}'", timeout=60)
          # the slot's replies carry the return mark, which routes them into
          # the tunnel's table
          out = som.succeed("ip route get ${clientIPv4} from ${slotIPv4} iif ve-web mark ${mark}")
          assert "dev wg-v4fwd" in out, out
          # without the mark rule they leave over br0 and never match
          som.succeed("ip rule del priority 101")
          client.fail(f"curl -s -m 5 {public}")
          som.succeed("ip rule add fwmark ${mark}/${mark} lookup 51820 priority 101")
          client.succeed(f"curl -s -m 10 {public} | grep -qx 'web peer=${clientIPv4}'")

      with subtest("the slot's own connections leave through the egress link"):
          out = som.succeed(in_slot + "${pkgs.curl}/bin/curl -s -m 5 http://${clientIPv4}:8081/")
          assert out.strip() == "client peer=${tunnelIPv4}", out
          out = som.succeed("ip route get ${clientIPv4} from ${slotIPv4} iif ve-web mark 0x2000000")
          assert "dev eth2" in out, out

      with subtest("the return mark leaves the Mullvad app's mark alone"):
          som.succeed("ip rule | grep -q 'fwmark ${markHex}/${markHex} lookup 51820'")
          out = som.succeed("ip route get ${clientIPv4} mark 0x6d6f6c65")
          assert "wg-v4fwd" not in out, out
    '';
}
