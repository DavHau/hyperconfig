# ./default.nix: `site` plays a routed site LAN (playa's 192.168.10.0/24 and
# fd2a:8abf:35da::/48, from home-networks) behind a zt-eu route, as som
# sees it. A refused user's connections there are refused at once; an
# unlisted user (roman on som) and root still get through, and the refused
# user still reaches the same host outside those prefixes. A noLan user
# (`nolan`) reaches no LAN address at all (v4, ULA, the "public" /64, the
# home LAN's public prefixes from home-networks), no yggdrasil or
# retiolum address but its allowed one (vit's, on som), no multicast or
# broadcast; only the client's own addresses and its allow entries. sshd
# gives it no forwarding, even to a destination its uid may reach.
{ pkgs }:
let
  snakeOil = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
pkgs.testers.runNixOSTest {
  name = "zt-eu-lan-guard";
  globalTimeout = 600;

  # Container tests (systemd-nspawn, no VM): the guard is an nftables
  # table, which works in a container's own netns on the host kernel.
  # 192.168.1.2 / 2001:db8:1::2 (machines are numbered by name).
  containers.site = {
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = "192.168.10.5";
        prefixLength = 24;
      }
    ];
    networking.interfaces.eth1.ipv6.addresses = [
      {
        address = "fd2a:8abf:35da::5";
        prefixLength = 64;
      }
      # yggdrasil: the allowed one (vit's role) and another fleet machine.
      {
        address = "201::5";
        prefixLength = 64;
      }
      {
        address = "202::5";
        prefixLength = 64;
      }
      # retiolum
      {
        address = "42::5";
        prefixLength = 64;
      }
      # the home LAN's router WAN link (home-networks' publicLanPrefixes)
      {
        address = "2405:9800:b014::5";
        prefixLength = 64;
      }
    ];
    services.nginx = {
      enable = true;
      virtualHosts.lan = {
        default = true;
        locations."/".return = ''200 "lan\n"'';
      };
    };
  };

  containers.client =
    { pkgs, ... }:
    {
      imports = [ ./default.nix ];
      networking.nftables.enable = true;
      # The site's LAN via its router, as zt-eu's managed routes install it.
      networking.interfaces.eth1.ipv4.routes = [
        {
          address = "192.168.10.0";
          prefixLength = 24;
          via = "192.168.1.2";
        }
      ];
      networking.interfaces.eth1.ipv6.routes =
        map
          (p: {
            address = p;
            prefixLength = if p == "fd2a:8abf:35da::" then 48 else 64;
            via = "2001:db8:1::2";
          })
          [
            "fd2a:8abf:35da::"
            "201::"
            "202::"
            "42::"
            "2405:9800:b014::"
          ];
      users.users.agent = {
        isNormalUser = true;
        uid = 1300;
      };
      users.users.roman = {
        isNormalUser = true;
        uid = 1301;
      };
      # noLan: no LAN at all but this host and its allow entry; the
      # LAN's "public" /64 is 2001:db8:1::/64 here.
      users.users.nolan = {
        isNormalUser = true;
        uid = 1302;
      };
      hyper.ztEuLanGuard.refusedUsers = [ "agent" ];
      hyper.ztEuLanGuard.noLan = {
        users = [ "nolan" ];
        prefixes = [ "2001:db8:1::/64" ];
        allow.nolan = [
          {
            address = "192.168.10.5";
            ports = [ 80 ];
          }
          {
            address = "201::5";
            ports = [
              22
              80
            ];
          }
        ];
      };
      # This host's own service, on its LAN address.
      services.nginx = {
        enable = true;
        virtualHosts.self = {
          default = true;
          locations."/".return = ''200 "self\n"'';
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
      # sshd for the forwarding cases. StrictModes off: the test
      # container's / and /nix/store are not root-owned.
      services.openssh = {
        enable = true;
        startWhenNeeded = false;
        settings.StrictModes = false;
      };
      # A password (unused) so sshd does not see the accounts as locked.
      users.users.nolan = {
        initialPassword = "x";
        openssh.authorizedKeys.keys = [ snakeOil.snakeOilPublicKey ];
      };
      users.users.roman = {
        initialPassword = "x";
        openssh.authorizedKeys.keys = [ snakeOil.snakeOilPublicKey ];
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.python3
      ];
    };

  testScript = ''
    lan = ["http://192.168.10.5/", "http://[fd2a:8abf:35da::5]/"]
    other = ["http://192.168.1.2/", "http://[2001:db8:1::2]/"]

    def curl(user, url):
        return client.execute(f"runuser -u {user} -- curl -sS --max-time 5 '{url}' 2>&1")

    start_all()
    site.wait_for_unit("nginx.service")
    client.wait_for_unit("multi-user.target")
    client.wait_until_succeeds("curl -sS --max-time 2 http://192.168.10.5/", timeout=60)
    client.wait_until_succeeds("curl -sS --max-time 2 http://[fd2a:8abf:35da::5]/", timeout=60)

    with subtest("the ruleset names every routed site prefix from home-networks"):
        rules = client.succeed("nft list table inet zt-eu-lan-guard")
        for p in ["192.168.10.0/24", "192.168.20.0/24", "fd2a:8abf:35da::/48", "fd99:a769:4eae::/48", "1300"]:
            assert p in rules, f"{p} missing:\n{rules}"
        assert "1301" not in rules, rules
        assert "chain nolan_1302" in rules, rules

    with subtest("a refused user is refused at once, v4 and v6"):
        for url in lan:
            rc, out = curl("agent", url)
            # 7 = could not connect (reset); 28 would be a timeout.
            assert rc == 7, f"agent {url}: curl exited {rc}: {out}"

    with subtest("unlisted users and root still reach the site LAN"):
        for user in ["roman", "root"]:
            for url in lan:
                rc, out = curl(user, url)
                assert rc == 0 and out.strip() == "lan", f"{user} {url}: {rc} {out}"

    with subtest("the refused user still reaches the host outside those prefixes"):
        for url in other:
            rc, out = curl("agent", url)
            assert rc == 0 and out.strip() == "lan", f"agent {url}: {rc} {out}"

    with subtest("noLan: every LAN address refused, v4 and v6, the /64 included"):
        for url in ["http://192.168.1.2/", "http://[2001:db8:1::2]/", "http://[fd2a:8abf:35da::5]/"]:
            rc, out = curl("nolan", url)
            assert rc == 7, f"nolan {url}: curl exited {rc}: {out}"

    with subtest("noLan: this host's own addresses and the allow entry still pass"):
        client.wait_for_unit("nginx.service")
        for url in ["http://192.168.1.1/", "http://[2001:db8:1::1]/", "http://127.0.0.1/"]:
            rc, out = curl("nolan", url)
            assert rc == 0 and out.strip() == "self", f"nolan {url}: {rc} {out}"
        rc, out = curl("nolan", "http://192.168.10.5/")
        assert rc == 0 and out.strip() == "lan", f"nolan allow: {rc} {out}"

    with subtest("noLan: yggdrasil only to the allowed address, no retiolum, no router WAN"):
        rc, out = curl("nolan", "http://[201::5]/")
        assert rc == 0 and out.strip() == "lan", f"nolan ygg allow: {rc} {out}"
        for url in ["http://[202::5]/", "http://[42::5]/", "http://[2405:9800:b014::5]/"]:
            rc, out = curl("nolan", url)
            assert rc == 7, f"nolan {url}: curl exited {rc}: {out}"
            rc, out = curl("roman", url)
            assert rc == 0 and out.strip() == "lan", f"roman {url}: {rc} {out}"
        rules = client.succeed("nft list chain inet zt-eu-lan-guard nolan_1302")
        for p in ["200::/7", "42::/16", "ff00::/8", "224.0.0.0/4", "255.255.255.255", "2405:9800:b014::/64", "2405:9800:b901:94e3::/64", "ct state established"]:
            assert p in rules, f"{p} missing:\n{rules}"

    with subtest("noLan: multicast and broadcast refused (sendto fails), others still send"):
        # Each datagram leaves with an explicit source/interface, so only
        # the guard can stop it.
        send = {
            "mcast4": "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.IPPROTO_IP,socket.IP_MULTICAST_IF,socket.inet_aton('192.168.1.1'));s.sendto(b'x',('224.0.0.251',5353))",
            "bcast4": "s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);s.bind(('192.168.1.1',0));s.sendto(b'x',('255.255.255.255',9))",
            "mcast6": "s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM);s.sendto(b'x',('ff02::1',9,0,socket.if_nametoindex('eth1')))",
        }
        for name, code in send.items():
            cmd = f"python3 -c \"import socket;{code}\" 2>&1"
            rc, out = client.execute(f"runuser -u nolan -- {cmd}")
            assert rc != 0 and "Operation not permitted" in out, f"nolan {name}: {rc} {out}"
            client.succeed(f"runuser -u roman -- {cmd}")

    with subtest("noLan: sshd forwards nothing for it, even where its uid may connect"):
        client.wait_for_unit("sshd.service")
        client.succeed("install -m 600 ${snakeOil.snakeOilPrivateKey} /root/k")
        # -F none: the container's /nix/store is not root-owned, which ssh
        # refuses for systemd's ssh_config.d include.
        ssh = "ssh -F none -i /root/k -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"
        req = "printf 'GET / HTTP/1.0\\r\\n\\r\\n' | "
        # 192.168.10.5:80 is in nolan's allow list: only sshd stops this.
        rc, out = client.execute(f"{req}{ssh} -W 192.168.10.5:80 roman@127.0.0.1 2>&1")
        assert rc == 0 and "lan" in out, f"roman -W: {rc} {out}"
        rc, out = client.execute(f"{req}{ssh} -W 192.168.10.5:80 nolan@127.0.0.1 2>&1")
        assert rc != 0 and "prohibited" in out, f"nolan -W: {rc} {out}"
        rc, out = client.execute(f"timeout 20 {ssh} -o ExitOnForwardFailure=yes -N -R 9999:192.168.10.5:80 nolan@127.0.0.1 2>&1")
        assert rc != 0 and rc != 124, f"nolan -R: {rc} {out}"
        rc, out = client.execute(f"{ssh} nolan@127.0.0.1 id -un")
        assert rc == 0 and out.strip() == "nolan", f"nolan plain ssh: {rc} {out}"
  '';
}
