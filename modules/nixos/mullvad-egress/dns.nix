# DNS of the tunneled users (./egress.nix) through the tunnel too, so the
# names they look up do not reach the host's resolver and its upstream.
#
#   - mullvad-egress-dns: an unbound on 127.0.0.153:53 that forwards only to
#     Mullvad's resolver inside the tunnel; it is a tunneled user itself.
#   - The units in dns.services and the user managers of the tunneled users
#     (user@<uid>.service, so every user unit too) see a resolv.conf naming
#     it, an nsswitch.conf without `resolve`, and neither nscd nor resolved's
#     varlink socket: both resolve as themselves, on the host's path.
#   - D-Bus calls of the tunneled users to resolved are refused, and their
#     DNS packets off the tunnel may only go to 127.0.0.153 (./egress.nix):
#     not to resolved's stub, dnscrypt-proxy or the LAN.
#
# Tunnel down: unbound's queries are refused (below), so these units get no
# DNS at all. /etc/hosts still answers first. Not covered: what a tunneled
# user runs outside these units (ssh or su logins, systemd-run of a system
# unit) still resolves through nscd on the host's path.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.mullvadEgress;
  user = "mullvad-dns";
  # Not 127.0.0.2: NixOS's /etc/hosts gives that one to the hostname.
  address = "127.0.0.153";
  # Mullvad's in-tunnel resolver: the tunnel gateways (api.mullvad.net
  # app/v1/relays, wireguard.ipv4_gateway/ipv6_gateway), which its app uses
  # as DNS by default (mullvadvpn-app, TunnelMetadata::gateways).
  upstream4 = "10.64.0.1";
  upstream6 = "fc00:bbbb:bbbb:bb01::1";

  # One resolver for every tunneled user, so no cache: a cached answer would
  # tell one agent what another looked up.
  unboundConf = pkgs.writeText "mullvad-egress-dns.conf" ''
    server:
      interface: ${address}
      port: 53
      access-control: 127.0.0.0/8 allow
      do-daemonize: no
      username: ""
      chroot: ""
      directory: "/"
      pidfile: ""
      use-syslog: no
      logfile: ""
      log-queries: no
      log-replies: no
      module-config: "iterator"
      cache-max-ttl: 0
      cache-max-negative-ttl: 0
      prefetch: no
      hide-identity: yes
      hide-version: yes
    forward-zone:
      name: "."
      forward-addr: ${upstream4}
      forward-addr: ${upstream6}
  '';

  # Stands in for resolved's directory: /etc/resolv.conf links into it, and
  # a whole-directory mount survives resolved replacing its files.
  resolveDir =
    let
      conf = pkgs.writeText "resolv.conf" ''
        nameserver ${address}
        options edns0
      '';
    in
    pkgs.linkFarm "mullvad-egress-resolve" {
      "stub-resolv.conf" = conf;
      "resolv.conf" = conf;
    };

  nsswitch = pkgs.writeText "mullvad-egress-nsswitch.conf" (
    lib.concatMapStringsSep "\n" (
      l: if lib.hasPrefix "hosts:" l then "hosts:     files myhostname dns" else l
    ) (lib.splitString "\n" config.environment.etc."nsswitch.conf".text)
  );

  # glibc asks nscd first, and nscd resolves with the host's nsswitch.conf.
  # The mount hides /run/nscd only if it exists when the unit starts and is
  # never replaced: tmpfiles creates it before any service, and nscd keeps
  # it across restarts (else a unit started before nscd, or any unit after
  # an nscd restart, sees the new directory and its socket).
  # The FIRST switch to this stops the old nscd still without Preserve, so
  # systemd deletes /run/nscd and the hide in every running tunneled unit
  # detaches from the new directory. After that deploy run
  # `mullvad-egress-restart-tunneled` (below) once.
  confine = {
    BindReadOnlyPaths = [
      "${resolveDir}:/run/systemd/resolve"
      # Defence in depth only: this lands on a store file that GC may
      # delete once the system using it is gone; resolv.conf and the hidden
      # nscd are what keep these lookups on the tunnel.
      "${nsswitch}:/etc/nsswitch.conf"
    ];
    InaccessiblePaths = [ "-/run/nscd" ];
  };

  uids = map (name: config.users.users.${name}.uid) cfg.users;

  # Re-applies the confinement to running units, e.g. after the first
  # deploy of the nscd hide (above). try-restart: only units that run.
  # The user managers go last; restarting one restarts all of that user's
  # user units. One unit per call, so an unknown or failing one does not
  # skip the rest; exits non-zero at the end if any failed.
  restartTunneled = pkgs.writeShellApplication {
    name = "mullvad-egress-restart-tunneled";
    text = ''
      failed=()
      # an array, so a list of one unit passes shellcheck (SC2043)
      units=(${
        lib.escapeShellArgs (
          map (s: "${s}.service") cfg.dns.services ++ map (uid: "user@${toString uid}.service") uids
        )
      })
      for unit in "''${units[@]}"; do
        systemctl try-restart "$unit" || failed+=("$unit")
      done
      if (( ''${#failed[@]} )); then
        echo "mullvad-egress-restart-tunneled: failed: ''${failed[*]}" >&2
        exit 1
      fi
    '';
  };
in
{
  options.hyper.mullvadEgress.dns.services = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "System units running as one of the tunneled users; they resolve through the tunnel.";
  };
  # for ./egress.nix's tunnelOnly loopback rule
  options.hyper.mullvadEgress.dns.address = lib.mkOption {
    type = lib.types.str;
    default = address;
    readOnly = true;
    internal = true;
    description = "The tunnel resolver's loopback address (port 53).";
  };

  config = {
    assertions = [
      {
        assertion = config.services.resolved.enable;
        message = "hyper.mullvadEgress: the tunnel's DNS replaces /run/systemd/resolve, which needs services.resolved.";
      }
    ]
    ++ map (name: {
      assertion = lib.elem (config.systemd.services.${name}.serviceConfig.User or null) cfg.users;
      message = "hyper.mullvadEgress.dns.services: '${name}' does not run as a tunneled user.";
    }) cfg.dns.services
    ++ map (name: {
      assertion = lib.elem name cfg.dns.services;
      message = "hyper.mullvadEgress.tunnelOnly.${name}: also list it in dns.services (its DNS is the tunnel's resolver, the only other loopback address it gets).";
    }) (lib.attrNames cfg.tunnelOnly);

    hyper.mullvadEgress.users = [ user ];
    users.users.${user} = {
      isSystemUser = true;
      uid = 1211;
      group = user;
    };
    users.groups.${user}.gid = 1211;

    systemd.tmpfiles.rules = lib.optional config.services.nscd.enable "d /run/nscd 0755 ${config.services.nscd.user} ${config.services.nscd.group} -";

    environment.systemPackages = [ restartTunneled ];

    systemd.services =
      lib.genAttrs cfg.dns.services (name: {
        serviceConfig =
          confine
          # ./egress.nix's tunnelOnly denies the rest of loopback (cgroup
          # filter by address; nftables by port: 53 here).
          // lib.optionalAttrs (cfg.tunnelOnly ? ${name}) { IPAddressAllow = [ address ]; };
      })
      // lib.optionalAttrs config.services.nscd.enable {
        nscd.serviceConfig.RuntimeDirectoryPreserve = "yes";
      }
      // {
        mullvad-egress-dns = {
          description = "DNS resolver of the Mullvad-tunneled users";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.unbound}/bin/unbound -d -p -c ${unboundConf}";
            User = user;
            Group = user;
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            # Netlink: unbound lists the interfaces at start.
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
              "AF_UNIX"
            ];
            Restart = "on-failure";
            RestartSec = 2;
          };
        };
      };

    # Raw drop-ins: a services entry would also set the user manager's PATH.
    # user@.service is never restarted by a switch; restart it by hand.
    systemd.units = lib.listToAttrs (
      map (
        uid:
        lib.nameValuePair "user@${toString uid}.service" {
          overrideStrategy = "asDropin";
          text = ''
            [Service]
            ${lib.concatMapStrings (p: "BindReadOnlyPaths=${p}\n") confine.BindReadOnlyPaths}
            ${lib.concatMapStrings (p: "InaccessiblePaths=${p}\n") confine.InaccessiblePaths}
          '';
        }
      ) uids
    );

    services.dbus.packages = [
      (pkgs.writeTextDir "share/dbus-1/system.d/mullvad-egress-dns.conf" ''
        <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
          "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
        <busconfig>
        ${lib.concatMapStrings (name: ''
          <policy user="${name}">
            <deny send_destination="org.freedesktop.resolve1"/>
          </policy>
        '') cfg.users}
        </busconfig>
      '')
    ];

    # With the tunnel down, its resolver's address would match 10.0.0.0/8 in
    # the kill switch and go out the uplink in clear.
    networking.nftables.tables.mullvad-egress-dns = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ip daddr ${upstream4} oifname != "wg-mullvad" reject with icmpx no-route
          ip6 daddr ${upstream6} oifname != "wg-mullvad" reject with icmpx no-route
        }
      '';
    };
  };
}
