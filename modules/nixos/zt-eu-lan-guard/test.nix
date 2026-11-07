# ./default.nix: `site` plays a routed site LAN (playa's 192.168.10.0/24 and
# fd2a:8abf:35da::/48, from home-networks) behind a zt-eu route, as som
# sees it. A refused user's connections there are refused at once; an
# unlisted user (roman on som) and root still get through, and the refused
# user still reaches the same host outside those prefixes.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "zt-eu-lan-guard";
  globalTimeout = 600;

  # 192.168.1.2 / 2001:db8:1::2 (nodes are numbered by name).
  nodes.site = {
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
    ];
    services.nginx = {
      enable = true;
      virtualHosts.lan = {
        default = true;
        locations."/".return = ''200 "lan\n"'';
      };
    };
  };

  nodes.client =
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
      networking.interfaces.eth1.ipv6.routes = [
        {
          address = "fd2a:8abf:35da::";
          prefixLength = 48;
          via = "2001:db8:1::2";
        }
      ];
      users.users.agent = {
        isNormalUser = true;
        uid = 1300;
      };
      users.users.roman = {
        isNormalUser = true;
        uid = 1301;
      };
      hyper.ztEuLanGuard.refusedUsers = [ "agent" ];
      environment.systemPackages = [ pkgs.curl ];
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
  '';
}
