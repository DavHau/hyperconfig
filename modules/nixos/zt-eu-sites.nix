# zt-eu's controller side of the bridged home LANs (../../home-networks):
# an IPv4 pool for every member, the routes to the sites' LANs via their
# routers, and each router's pinned IPv4 (the address those routes name).
# Imported through the zt-eu instance's controller role (edi,
# ../flake-parts/nixosConfigurations.nix), which also authorizes the routers.
#
# clan's zerotier service writes the network JSON from
# clan.core.zerotier.networks.<instance>.settings (a json-typed option:
# lists merge, booleans need mkForce). It has no per-member address option,
# so the pins go through the controller API, the way clan's
# zerotier-autoaccept unit authorizes members.
{ lib, pkgs, ... }:
let
  net = import ../../home-networks { inherit lib; };
in
{
  clan.core.zerotier.networks.${net.instance}.settings = {
    v4AssignMode.zt = lib.mkForce true;
    ipAssignmentPools = [
      {
        ipRangeStart = net.ipv4.poolStart;
        ipRangeEnd = net.ipv4.poolEnd;
      }
    ];
    inherit (net) routes;
  };

  # A member whose ipAssignments already hold an address inside an on-link
  # route gets nothing from the pool, so a pinned router keeps exactly its
  # address. The member records persist in controller.d; the unit reruns
  # whenever the pins change. No ordering against zerotier-autoaccept (a
  # Type=simple unit, so After= would only wait for its start): a POST
  # merges into the member record, and autoaccept sets `authorized` only.
  systemd.services."zerotier-pin-${net.instance}" = {
    description = "Pin the site routers' IPv4 on zerotier network ${net.instance}";
    wantedBy = [ "multi-user.target" ];
    after = [ "zerotierone.service" ];
    requires = [ "zerotierone.service" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # The auth token reaches curl through a header file (bash process
    # substitution, printf a builtin), never through any argv.
    script = ''
      token=$(< /var/lib/zerotier-one/authtoken.secret)
      ${lib.concatMapStrings (r: ''
        curl -fsS -o /dev/null --retry 30 --retry-delay 2 --retry-all-errors \
          -H @<(printf 'X-ZT1-AUTH: %s\n' "$token") -X POST \
          -d ${lib.escapeShellArg (builtins.toJSON { ipAssignments = [ r.ztIpv4 ]; })} \
          http://localhost:9993/controller/network/${net.networkId}/member/${r.ztNodeId}
        echo "${r.name} (${r.ztNodeId}): ${r.ztIpv4}"
      '') net.routers}
    '';
  };
}
