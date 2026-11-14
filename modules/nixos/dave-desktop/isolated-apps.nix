/*
  "Hermes (<label>)": for each app marked `isolated` in ./apps.nix (voice,
  infra-space), the hermes desktop app run in a container of its own on
  this desktop, shown on Dave's Wayland session through ../space-gui,
  connected only to that dashboard, https://<account>.davhau.fyi, with its
  pocket-id sign-in. App and sign-in mechanics:
  ../space-gui/hermes-app.nix.

  Why a container: voice is untrusted (it takes spoken input from anyone
  near the Voice PE), and infra-space's app has no business seeing Dave's
  session either. A dashboard renders what its agent writes, so the app
  showing it gets nothing of Dave's: not his home, his ssh agent, his
  session bus or his other agents' app (whose cookies sign in to
  dave-hermes and the others), and the agent's account needs no ssh keys
  (no TUI entry; som's assertion in machines/som/hermes-agents.nix skips
  these apps). It needs no local infra-space or space either: the app
  only talks https, so every desktop gets the same set.

  Per app, container `isolated.name` (default `hermes-<account>`; at most
  12 characters: the host's veth is ve-<name>), through the spaces' host
  side (../spaces/host.nix):
    - private veth, v4 10.235.1.<4i+2> (this host .<4i+1>), v6
      fd23:5ace:1:<i>::2, `index` from ./apps.nix; NAT out;
    - confined like the named spaces (../spaces/blocked-destinations.nix):
      the internet, and of this host DNS only; no mesh, no LAN, no other
      container (on som its own public dashboards are reached by their
      public v4 address, as from anywhere);
    - no sshd, no credentials, no TPM: nothing logs in, no secret enters;
    - no nix: the host's nix-daemon socket is made inaccessible in the
      guest (`hostNixDaemon = false`), since that daemon builds in this
      host's network namespace and on its build machines, outside the
      confinement; the store is there read-only, the guest runs from it;
    - nothing on this host but root reaches into it (the output gate);
    - the guest's user `hermes` (uid from ./apps.nix), its home
      /var/lib/hermes-desktop-spaces/<account>/home here: the app's
      config, cookies and tokens persist there and nowhere else.
  The guest system itself is minimal: that user, the host's resolver, a
  firewall that admits nothing in (space-gui's sign-in forward enters the
  container's loopback, which the firewall leaves open).

  Wayland app id and launcher `space-gui-hermes-<account>`.

  Forwarding: the NAT out (../spaces/host.nix) turns on IPv4 and IPv6
  forwarding for the whole host. On a desktop that forwards nothing else
  (vit) that would let a LAN neighbour route through it into the mesh and
  back, so `hyper.daveDesktop.restrictForwarding` (default on) adds a
  forward chain of its own that passes only traffic from or to these
  containers' veths (and waydroid's and podman's bridges where enabled)
  and replies, and drops every other forwarded packet.
  amy and som forward on purpose (infra-space, docker, container slots,
  spaces, mullvad egress) and set it to false.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  desktop = config.services.hyperhermes.desktop;
  spaceHost = import ../spaces/host.nix { inherit config lib pkgs; };
  apps = lib.filterAttrs (_: a: a ? isolated) (import ./apps.nix);

  user = "hermes";
  guestHome = "/home/${user}";
  containerName = account: a: a.isolated.name or "hermes-${account}";
  url = account: "https://${account}.${desktop.domain}";

  app =
    account: a:
    import ../space-gui/hermes-app.nix { inherit lib pkgs desktop; } {
      appId = "hermes-${account}";
      primary = account;
      remotes.${account} = {
        inherit (a) label;
        url = url account;
      };
    };

  spaceConfig =
    account: a:
    let
      name = containerName account a;
      inherit (a.isolated) index uid;
      v4 = n: "10.235.1.${toString (4 * index + n)}";
      v6 = n: "fd23:5ace:1:${toString index}::${toString n}";
      stateDir = "/var/lib/hermes-desktop-spaces/${account}";
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.stringLength name <= 12;
            message = "dave-desktop: container ${name} is longer than 12 characters (its veth ve-${name} must fit 15); set isolated.name for ${account} in dave-desktop/apps.nix";
          }
        ];

        hyper.spaceGui = {
          containers.${name} = {
            inherit user uid;
            home = guestHome;
            openOrigins = [ (url account) ];
          };
          apps."hermes-${account}" = {
            container = name;
            command = [ "${app account a}" ];
            desktopName = "Hermes (${a.label})";
            icon = "${desktop.package}/share/hermes-desktop/dist/hermes.png";
          };
        };
      }
      (spaceHost {
        inherit
          name
          uid
          stateDir
          guestHome
          ;
        homeDir = "${stateDir}/home";
        hostAddress = v4 1;
        localAddress = v4 2;
        hostAddress6 = v6 1;
        localAddress6 = v6 2;
        tpm = false;
        credentials = { };
        hostNixDaemon = false;
        confine = true;
        blockedDestinations = import ../spaces/blocked-destinations.nix;
        specialArgs = { };
        guestConfig = {
          system.stateVersion = "26.05";
          networking.useHostResolvConf = false;
          networking.nameservers = [ (v4 1) ];
          users.groups.${user}.gid = uid;
          users.users.${user} = {
            isNormalUser = true;
            inherit uid;
            home = guestHome;
            group = user;
            description = "Hermes desktop app (${account})";
          };
        };
      })
    ];
  # waydroid's and rootful podman's default bridges (on vit) NAT out
  # through this host as well and stay allowed.
  veths =
    lib.mapAttrsToList (account: a: "ve-${containerName account a}") apps
    ++ lib.optional config.virtualisation.waydroid.enable "waydroid0"
    ++ lib.optional config.virtualisation.podman.enable "podman0";
  vethSet = "{ ${lib.concatMapStringsSep ", " (v: ''"${v}"'') veths} }";

  # Ids of host users and groups other than the containers' own (their
  # guest users live in the guest config, not here). Users with uid = null
  # (allocated from 1000 up at activation) and imperative users aren't seen.
  hostIds =
    attrs: field:
    lib.filter (id: id != null) (lib.mapAttrsToList (_: u: u.${field} or null) attrs);
  hostUids = hostIds config.users.users "uid";
  hostGids = hostIds config.users.groups "gid";
in
{
  imports = [ ../space-gui ];

  options.hyper.daveDesktop.restrictForwarding = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Forward only traffic from or to the isolated apps' container veths
      (plus established/related replies) and drop every other forwarded
      packet. Their NAT turns on IP forwarding host-wide; set this to
      false on hosts that forward for other reasons too (amy, som).
    '';
  };

  config = lib.mkMerge (
    [
      (lib.mkIf (config.hyper.daveDesktop.restrictForwarding && apps != { }) {
        networking.nftables.tables.dave-desktop-forward = {
          family = "inet";
          content = ''
            chain forward {
              type filter hook forward priority filter; policy drop;
              # A forwarded packet never carries one of our own addresses
              # as source; drop spoofed ones before the conntrack shortcut.
              fib saddr type local drop
              ct state established,related accept
              # Inbound to waydroid0/podman0 is allowed on purpose (podman -p).
              iifname ${vethSet} accept
              oifname ${vethSet} accept
            }
          '';
        };
      })
      {
        hyper.spaceGui.enable = true;
        assertions =
          let
            distinct = list: lib.length list == lib.length (lib.unique list);
            all = field: lib.mapAttrsToList (_: a: a.isolated.${field}) apps;
          in
          [
            {
              assertion = distinct (all "index");
              message = "dave-desktop: two apps in dave-desktop/apps.nix share an isolated.index";
            }
            {
              # home-networks/sites.nix claims 10.235.1.0/26: sixteen /30s.
              assertion = lib.all (i: i >= 0 && i < 16) (all "index");
              message = "dave-desktop: an isolated.index is outside 0..15 (10.235.1.0/26, claimed in home-networks/sites.nix)";
            }
            {
              assertion = distinct (all "uid");
              message = "dave-desktop: two apps in dave-desktop/apps.nix share an isolated.uid";
            }
            {
              assertion = distinct (lib.mapAttrsToList containerName apps);
              message = "dave-desktop: two apps in dave-desktop/apps.nix share a container name";
            }
          ]
          # The guest's user and group have the same ids on this host (no
          # user namespace, and its home here is owned by them): a host
          # user or group with that id would own the app's files.
          ++ lib.mapAttrsToList (account: a: {
            assertion = !(lib.elem a.isolated.uid hostUids) && !(lib.elem a.isolated.uid hostGids);
            message = "dave-desktop: isolated.uid ${toString a.isolated.uid} of ${account} (dave-desktop/apps.nix) is also a uid or gid of a user/group on this host";
          }) apps;
      }
    ]
    ++ lib.mapAttrsToList spaceConfig apps
  );
}
