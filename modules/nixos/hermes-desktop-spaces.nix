/*
  "Hermes (<agent>)": for each som agent marked `isolatedDesktop` in
  ./hermes-desktop-agents.nix (voice), the hermes desktop app run in a
  container of that agent's own on this desktop, shown on Dave's Wayland
  session through ./space-gui, connected only to that agent's dashboard,
  https://<agent>.davhau.fyi, with its pocket-id sign-in. The same kind of
  launcher as infra-space's (./infra-space/desktop-app.nix); app and
  sign-in mechanics: ./space-gui/hermes-app.nix.

  Why a container: such an agent is untrusted (voice takes spoken input
  from anyone near the Voice PE). Its dashboard renders what the agent
  writes, so the app showing it gets nothing of Dave's: not his home, his
  ssh agent, his session bus or his other agents' app (whose cookies sign
  in to dave-hermes and the others), and the agent's account needs no ssh
  keys (no TUI entry; som's assertion in machines/som/hermes-agents.nix
  skips these agents).

  Per agent, container `isolatedDesktop.name` (default `hermes-<agent>`;
  at most 12 characters: the host's veth is ve-<name>), through the
  spaces' host side (./spaces/host.nix):
    - private veth, v4 10.235.1.<4i+2> (this host .<4i+1>), v6
      fd23:5ace:1:<i>::2, `index` from ./hermes-desktop-agents.nix; NAT out;
    - confined like the named spaces (./spaces/blocked-destinations.nix):
      the internet, and of this host DNS only; no mesh, no LAN, no other
      container;
    - no sshd, no credentials, no TPM: nothing logs in, no secret enters;
    - no nix: the host's nix-daemon socket is made inaccessible in the
      guest (`hostNixDaemon = false`), since that daemon builds in this
      host's network namespace and on its build machines, outside the
      confinement; the store is there read-only, the guest runs from it;
    - nothing on this host but root reaches into it (the output gate);
    - the guest's user `hermes` (uid from ./hermes-desktop-agents.nix), its
      home /var/lib/hermes-desktop-spaces/<agent>/home here: the app's
      config, cookies and tokens persist there and nowhere else.
  The guest system itself is minimal: that user, the host's resolver, a
  firewall that admits nothing in (space-gui's sign-in forward enters the
  container's loopback, which the firewall leaves open).

  Imported by the desktops that show the app (amy).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  desktop = config.services.hyperhermes.desktop;
  spaceHost = import ./spaces/host.nix { inherit config lib pkgs; };
  agents = lib.filterAttrs (_: a: a ? isolatedDesktop) (import ./hermes-desktop-agents.nix);

  user = "hermes";
  guestHome = "/home/${user}";
  containerName = agent: a: a.isolatedDesktop.name or "hermes-${agent}";
  url = agent: "https://${agent}.${desktop.domain}";

  app =
    agent: a:
    import ./space-gui/hermes-app.nix { inherit lib pkgs desktop; } {
      appId = "hermes-${agent}";
      primary = agent;
      remotes.${agent} = {
        inherit (a) label;
        url = url agent;
      };
    };

  spaceConfig =
    agent: a:
    let
      name = containerName agent a;
      inherit (a.isolatedDesktop) index uid;
      v4 = n: "10.235.1.${toString (4 * index + n)}";
      v6 = n: "fd23:5ace:1:${toString index}::${toString n}";
      stateDir = "/var/lib/hermes-desktop-spaces/${agent}";
    in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.stringLength name <= 12;
            message = "hermes-desktop-spaces: container ${name} is longer than 12 characters (its veth ve-${name} must fit 15); set isolatedDesktop.name for ${agent} in hermes-desktop-agents.nix";
          }
        ];

        hyper.spaceGui = {
          containers.${name} = {
            inherit user uid;
            home = guestHome;
            openOrigins = [ (url agent) ];
          };
          apps.${name} = {
            container = name;
            command = [ "${app agent a}" ];
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
        blockedDestinations = import ./spaces/blocked-destinations.nix;
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
            description = "Hermes desktop app (${agent})";
          };
        };
      })
    ];
in
{
  imports = [ ./space-gui ];

  config = lib.mkMerge (
    [
      {
        hyper.spaceGui.enable = true;
        assertions =
          let
            distinct = list: lib.length list == lib.length (lib.unique list);
            all = field: lib.mapAttrsToList (_: a: a.isolatedDesktop.${field}) agents;
          in
          [
            {
              assertion = distinct (all "index");
              message = "hermes-desktop-spaces: two agents in hermes-desktop-agents.nix share an isolatedDesktop.index";
            }
            {
              # home-networks/sites.nix claims 10.235.1.0/28: four /30s.
              assertion = lib.all (i: i >= 0 && i < 4) (all "index");
              message = "hermes-desktop-spaces: an isolatedDesktop.index is outside 0..3 (10.235.1.0/28, claimed in home-networks/sites.nix)";
            }
            {
              assertion = distinct (all "uid");
              message = "hermes-desktop-spaces: two agents in hermes-desktop-agents.nix share an isolatedDesktop.uid";
            }
          ];
      }
    ]
    ++ lib.mapAttrsToList spaceConfig agents
  );
}
