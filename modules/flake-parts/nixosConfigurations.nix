{ self, lib, inputs, ... }: let
  allSystems = [ "x86_64-linux" "aarch64-linux" ];

  pkgsCross = lib.genAttrs allSystems (
    buildSystem:
      lib.genAttrs allSystems (
        crossSystem:
          import inputs.nixpkgs {
            inherit crossSystem;
            system = buildSystem;
          }
      )
  );

  # som's hermes agents (machines/som/hermes-dashboards.nix): the pocket-id
  # clients hyperhermes' lib.sso.oidcClients derives (one confidential
  # client and one group per agent for its dashboard at
  # https://<agent>.<domain>/, joined by the agent's account, the front
  # door's client `hermes`, and the confidential client hermes-serve for
  # every agent's private serve ports, https://<port>.<agent>.<domain>/,
  # with a host-wildcard callback per agent; hyperhermes' dashboards and
  # publish modules say why confidential, why every app login asks for the
  # passkey, and why a pattern is safe).
  somDashboards = import ../../machines/som/hermes-dashboards.nix;
  hermesSso = inputs.hyperhermes.lib.sso;
  somHermesClients = hermesSso.oidcClients {
    inherit (somDashboards) domain accounts frontDoor;
    publish = true;
  };
  # The infra-space agent's dashboard on som (modules/nixos/infra-space/
  # dashboard.nix): one more client and group of the same convention, for
  # the account in its data file. Not in hermes-dashboards.nix: that agent
  # runs in som's container, not on som, and has no serve ports.
  infraSpaceDashboard = import ../nixos/infra-space/dashboard-account.nix;
  infraSpaceAccounts = { ${infraSpaceDashboard.name} = infraSpaceDashboard.account; };
  infraSpaceClients = hermesSso.oidcClients {
    inherit (somDashboards) domain;
    accounts = infraSpaceAccounts;
  };
  # The spaces on som publish their port windows behind the serve ports'
  # login (modules/nixos/spaces/publish.nix): the client hermes-serve gets
  # a callback pattern per space and admits its group space-<name>, which
  # the space's owners (registry.nix) join.
  somSpaces = lib.filterAttrs (_: s: s.machine == "som") (import ../nixos/spaces/registry.nix);
  spaceGroupOf = name: "space-${name}";
  spaceGroups = lib.foldlAttrs (acc: name: s:
    lib.foldl' (a: o: a // { ${o} = (a.${o} or [ ]) ++ [ (spaceGroupOf name) ]; }) acc (s.owners or [ "dave" ])
  ) { } somSpaces;
  dashboardGroups = lib.zipAttrsWith (_: lib.concatLists) [
    (hermesSso.accountGroups (somDashboards.accounts // infraSpaceAccounts))
    spaceGroups
  ];
  withDashboardGroups = users:
    let
      unknown = lib.filter (a: !(users ? ${a})) (lib.attrValues somDashboards.accounts);
    in
      assert lib.assertMsg (unknown == [ ])
        "machines/som/hermes-dashboards.nix names accounts the oidc instance does not declare: ${toString unknown}";
      lib.mapAttrs (name: u: u // { groups = (u.groups or [ ]) ++ dashboardGroups.${name} or [ ]; }) users;
  homeNetworks = import ../../home-networks { inherit lib; };
  fleetMachines = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../machines));
in {
  flake =
    let
      clan = (inputs.clan-core.lib.clan {
        inherit self;

        pkgsForSystem = system: import inputs.nixpkgs {
          inherit system;
          # config = {
          #   replaceStdenv = ({ pkgs }: pkgs.withCFlags [ "-funroll-loops" "-O3" "-march=x86-64-v3" ] pkgs.stdenv);
          # };
          # config.contentAddressedByDefault = true;
          config = import ../nixos/nixpkgs-config.nix {inherit lib;};
        };

        specialArgs = {
          inherit inputs pkgsCross self;
        };

        meta.name = "DavClan";
        meta.domain = "d";

        # Vars are encrypted with clan's age backend, decryptable only by
        # the TPM age identities of the infra-space containers on som and
        # amy (../nixos/infra-space/age-recipients.nix). The encrypted store
        # is not in this repo: it is DavHau/hyperconfig-secrets, checked out
        # in each container at CLAN_AGE_STORE_DIR and kept in sync by its
        # `clan` wrapper (../nixos/infra-space/guest.nix).
        vars.settings.secretStore = "age";
        vars.settings.age.externalStore = true;
        vars.settings.recipients.default = lib.attrValues (import ../nixos/infra-space/age-recipients.nix);
        secrets.age.plugins = [ "age-plugin-tpm" ];

        modules = {
          nix-cache = ../../modules/clan/nix-cache;
          wireguard = ../../modules/clan/wireguard;
          ncps = inputs.ncps + "/clanServices/ncps";
          cctl = ../../modules/clan/cctl;
          remote-building = ../../modules/clan/remote-building;
          oidc = ../../modules/clan/oidc;
        };

        # add machines to their hosts
        inventory = {
          machines = {
            installer.tags = [ "wifi-home" ];
            cm-pi.tags = [ "wifi-home" ];
            som.deploy.targetHost = "root@som.d";
            # `clan machines update edi`/`sgp` builds on the machine running
            # it and copies the closure over; neither machine evaluates or
            # builds the flake itself (sgp has 1 vCPU, 1G RAM).
            edi.deploy.buildHost = "localhost";
            sgp.deploy.buildHost = "localhost";
            # joy.deploy.targetHost = "joy.dave";
          };

          instances = {
            # Root password on every machine (replaces the deprecated clan
            # `admin` service; its root-password vars were moved over to
            # user-password-root, so the passwords stayed the same).
            user-root = {
              module.name = "users";
              module.input = "clan-core";
              roles.default.tags.all = { };
              roles.default.settings = {
                user = "root";
                prompt = true;
              };
            };
            # zt-home = {
            #   module.name = "zerotier";
            #   roles.peer.tags.all = {};
            #   roles.controller.machines.nas = {};
            #   roles.controller.settings.allowedIps = [
            #     "7c29125877"
            #   ];
            # };
            # The clan-managed zerotier network. Its controller (edi) also
            # bridges the home LANs (../../home-networks): it authorizes the
            # site routers and routes their LANs (../nixos/zt-eu-sites.nix).
            zt-eu = {
              module.name = "zerotier";
              roles.peer.tags.all = {};
              roles.controller.machines.edi = {};
              roles.controller.extraModules = [ ../nixos/zt-eu-sites.nix ];
              roles.controller.settings.allowedIds = [
                "2f4e835d67" # stefan's laptop (external)
              ] ++ map (r: r.ztNodeId) homeNetworks.routers;
            };
            importer.roles.default.extraModules = [
              ../../modules/nixos/common.nix
              ../../modules/nixos/networkmanager-restart-late.nix
            ];
            # clan's age backend ignores vars' restartUnits
            # (../nixos/clan-vars-restart-units.nix does them), on every
            # machine of the inventory.
            clan-vars-restart-units = {
              module.name = "importer";
              module.input = "clan-core";
              roles.default.tags.all = { };
              roles.default.extraModules = [ ../nixos/clan-vars-restart-units.nix ];
            };
            # Every machine but the installer keeps a mirror of the secrets
            # repo (../nixos/clan-secrets-mirror.nix); the installer only
            # boots from RAM and has no state to keep it in. Taken from
            # ../../machines, so new machines get it too.
            clan-secrets-mirror = {
              module.name = "importer";
              module.input = "clan-core";
              roles.default.machines = lib.genAttrs (lib.remove "installer" fleetMachines) (_: { });
              roles.default.extraModules = [ ../nixos/clan-secrets-mirror.nix ];
            };
            dave-user = { #
              module.name = "users";
              roles.default.tags.all = { }; #
              roles.default.settings = {
                user = "dave"; #
                groups = [
                  "wheel" # Allow using 'sudo'
                  "networkmanager" # Allows to manage network connections.
                  "video" # Allows to access video devices.
                  "input" # Allows to access input devices.
                ];
              };
            };
            joy-user = {
              module.name = "users";
              roles.default.machines.joy = {};
              roles.default.settings = {
                user = "joy";
                groups = [
                  "wheel" # Allow using 'sudo'
                  "networkmanager" # Allows to manage snetwork connections.
                  "video" # Allows to access video devices.
                  "input" # Allows to access input devices.
                ];
              };
            };
            wifi-home = {
              module.name = "wifi";
              module.input = "clan-core";
              roles.default.settings.networks.home = {};
              roles.default.tags.wifi-home = {};
            };
            nix-cache = {
              module.name = "nix-cache";
              module.input = "self";
              roles.server.machines = {
                amy = { };
                som = { };
                vit = { };
                bam = { };
              };
              roles.client.tags.all = { };
            };
            # TODO: enable backups again
            dave-backup = {
              module.name = "borgbackup";
              module.input = "clan-core";
              roles.server.machines.nas = {};
              roles.client.machines.amy = {};
              roles.client.settings.exclude = import ../backup-exclude.nix;
              roles.server.settings.directory = "/pool11/enc/clan-backup";
            };
            sshd = {
              module.name = "sshd";
              module.input = "clan-core";
              roles.server.tags.all = {};
              # Fleet-wide `agent` account (sbox ssh identity); reaches all
              # machines through this all-tags instance. infra-space's
              # fleet root key rides along the same way, in a key file of
              # its own (fleet-access.nix says why).
              roles.server.extraModules = [
                ../../modules/nixos/agent-user.nix
                ../../modules/nixos/infra-space/fleet-access.nix
              ];
              # Root on every machine.
              roles.server.settings.authorizedKeys = import ../admin-ssh-keys.nix;
              roles.client.tags.all = {};
            };
            remote-building = {
              module.name = "remote-building";
              module.input = "self";
              roles.builder.machines.som = {};
              roles.client.machines.amy.settings.barToggle = true;
            };

            # Pocket ID at id.davhau.com (modules/clan/oidc). som's hermes
            # dashboards sign in with hermes' own OIDC login, one confidential
            # client and group hermes-<agent> per agent, and the agents'
            # private serve ports with client hermes-serve, open to those
            # groups, all derived from machines/som/hermes-dashboards.nix
            # (hyperhermes' lib.sso.oidcClients). The
            # `hermes` group opens som's front door (the redirect at
            # hermes.davhau.com) and the mail owner page.
            oidc = {
              module.name = "oidc";
              module.input = "self";
              roles.server.machines.edi.settings = {
                appUrl = "https://id.davhau.com";
                appName = "DavHau";
                logo = ../../assets/davhau-avatar.png;
                users = withDashboardGroups {
                  dave = {
                    email = "need-more-ram@davhau.com";
                    displayName = "Dave";
                    admin = true;
                    groups = [ "apps" "hermes" "stats" "voices" ];
                  };
                  stefan = { displayName = "Stefan"; groups = [ "hermes" ]; };
                  pinpox = { displayName = "Pinpox"; groups = [ "hermes" ]; };
                  adam = { displayName = "Adam"; groups = [ "hermes" ]; };
                  j = { displayName = "J"; groups = [ "hermes" ]; };
                  willi = { displayName = "Willi"; groups = [ "hermes" ]; };
                  domi = { displayName = "Domi"; groups = [ "hermes" ]; };
                  rti = { displayName = "Rti"; groups = [ "hermes" ]; };
                  chris = { displayName = "Chris"; groups = [ "hermes" ]; };
                  b3x = { displayName = "B3x"; groups = [ "hermes" ]; };
                  egg = { displayName = "Egg"; groups = [ "hermes" ]; };
                  momentum = { displayName = "Momentum"; groups = [ "hermes" ]; };
                  roman = { displayName = "Roman"; groups = [ "hermes" ]; };
                  daniel = { displayName = "Daniel"; groups = [ "hermes" ]; };
                  nico = { displayName = "Nico"; groups = [ "apps" ]; };
                  # The coding agent's account for end-to-end login tests
                  # (`pocket-id-enroll agent` on edi gives it a one-time
                  # session, no passkey needed). In `hermes` on purpose: it
                  # owns no agent, so it exercises the front door's 403 path.
                  agent = { email = "agent@davhau.com"; displayName = "Agent"; groups = [ "apps" "hermes" ]; };
                };
              };
              roles.client.machines.bam.settings.clients = {
                nextcloud = {
                  name = "Nextcloud";
                  callbackURLs = [ "https://nc.davhau.com/apps/user_oidc/code" ];
                  allowedGroups = [ "apps" ];
                };
                vikunja = {
                  name = "Vikunja";
                  callbackURLs = [ "https://tasks.davhau.com/auth/openid/davhau" ];
                  allowedGroups = [ "apps" ];
                };
              };
              roles.client.machines.cm-pi.settings.clients.home-assistant = {
                name = "Home Assistant";
                callbackURLs = [ "https://bearhouse.davhau.com/auth/oidc/callback" ];
                public = true;
                allowedGroups = [ "apps" ];
              };
              # som's oauth2-proxy front door `hermes`: hermes.davhau.com
              # (redirects to the account's dashboard), whose client the agent
              # mail owner page shares (hyperhermes' mail module, its own
              # oauth2-proxy, its own callback), the private serve
              # ports' oauth2-proxy (hermes-serve), plus one client per agent
              # dashboard, and infra-space's (from its own data file).
              roles.client.machines.som.settings.clients = somHermesClients // infraSpaceClients // {
                ${hermesSso.publishClientId} = somHermesClients.${hermesSso.publishClientId} // {
                  callbackURLs = somHermesClients.${hermesSso.publishClientId}.callbackURLs
                    ++ lib.mapAttrsToList (name: _: "https://*.${name}.${somDashboards.domain}${hermesSso.publishLoginPrefix}/callback") somSpaces;
                  allowedGroups = somHermesClients.${hermesSso.publishClientId}.allowedGroups
                    ++ map spaceGroupOf (lib.attrNames somSpaces);
                };
                hermes = somHermesClients.hermes // {
                  callbackURLs = somHermesClients.hermes.callbackURLs ++ [
                    "https://mailgate.${somDashboards.frontDoor}/oauth2/callback"
                  ];
                };
              };
              # Grafana at stats.davhau.com (modules/nixos/monitoring-grafana-sso.nix).
              roles.client.machines.edi.settings.clients.grafana = {
                name = "Grafana";
                callbackURLs = [ "https://stats.davhau.com/login/generic_oauth" ];
                pkce = true;
                allowedGroups = [ "stats" ];
              };
              # vit's TTS voice picker at voices.davhau.com, Dave only
              # (modules/nixos/wyoming-local-speech/voices-sso.nix).
              roles.client.machines.edi.settings.clients.voices = {
                name = "Voices";
                callbackURLs = [ "https://voices.davhau.com/oauth2/callback" ];
                pkce = true;
                allowedGroups = [ "voices" ];
              };
            };

            p2p-ssh-iroh = {
              module.name = "p2p-ssh-iroh";
              module.input = "clan-core";
              roles.server.tags.all = {};
            };

            # cctl = {
            #   module.name = "cctl";
            #   module.input = "self";
            #   roles.server.machines.amy.settings.user = "grmpf";
            #   roles.server.extraModules = [
            #     { networking.firewall.interfaces."ztfwr2j6pf".allowedTCPPorts = [ 80 ]; }
            #   ];
            # };

            # VPNs
            yggdrasil = {
              roles.default.tags = ["all"];
            };
            hyprspace = {
              module.input = "clan-community";
              roles.default.tags = ["all"];
            };
            wg-casa = {
              module.name = "wireguard";
              module.input = "self";
              roles.controller = {
                machines.nas.settings = {

                  ipv4.enable = true;
                  ipv4.address = "10.42.1.1/24";

                  externalPeers = {
                    dave-handy = {
                      allowInternetAccess = true;
                      ipv4.address = "10.42.1.50/32";
                    };
                    papa-handy = {
                      allowInternetAccess = true;
                      ipv4.address = "10.42.1.51/32";
                    };
                    papa-laptop = {
                      allowInternetAccess = true;
                      ipv4.address = "10.42.1.52/32";
                    };
                    papa-tv-stick = {
                      allowInternetAccess = true;
                      ipv4.address = "10.42.1.53/32";
                    };
                  };
                };
                settings = {
                  # Public endpoint where this controller can be reached
                  endpoint = "wg-casa.bruch-bu.de";
                  # Optional: Change the UDP port (default: 51820)
                  port = 51820;
                };
              };
            };
            wg-edi = {
              module.name = "wireguard";
              module.input = "clan-core";
              roles.controller.machines.edi.settings = {
                endpoint = "casa.bruch-bu.de";
                # Different port from wg-casa (which lives on the same NAT/WAN IP)
                port = 51821;
              };
              roles.peer.machines = lib.genAttrs [
                "amy" "bam" "cm-pi" "joy" "nas"
                "vit" "installer"
              ] (_: { });
            };
            # Fast local star for the vault NFS traffic: bam is the controller
            # with its LAN address as endpoint, so peers exchange traffic with
            # bam directly over the LAN (no hairpin through a remote hub, unlike
            # wg-edi). Kernel WireGuard - saturates 2.5GbE where the userspace
            # meshes (yggdrasil ~365 Mbit/s measured) cap out. The wg key list
            # doubles as the NFS mount ACL (see modules/nixos/vault-nfs-server.nix).
            wg-vault = {
              module.name = "wireguard";
              module.input = "self";
              roles.controller.machines.bam.settings = {
                # bam's static LAN alias (not the DHCP lease, which has
                # changed before; not provider IPv6, which rotates). Defined
                # in modules/nixos/vault-nfs-server.nix.
                endpoint = "192.168.8.250";
                # 51820/51821/51822 are taken by wg-casa/wg-edi/vibepn.
                port = 51823;
              };
              roles.peer.machines = lib.genAttrs [ "amy" "vit" "som" ] (_: { });
            };
            # ncps = {
            #   module.name = "ncps";
            #   module.input = "self";
            #   roles.server.machines.bam = {
            #     settings.caches = [
            #       "https://cache.nixos.org"
            #     ];
            #     settings.publicKeys = [
            #       "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            #     ];
            #   };
            #   roles.client.machines.amy = {};
            #   roles.client.machines.bam = {};
            # };

            # clan-core monitoring: Alloy on every machine pushes metrics
            # (Mimir) and journal logs (Loki) to edi over zt-eu (edi.d);
            # Grafana at http://edi.d/grafana/. The service sets no retention,
            # so the server role adds it plus a loopback ring fix. Alerts
            # (Grafana unified alerting, Telegram) live in monitoring-alerts.nix;
            # clients add ZFS pool health and capacity for its pool rules.
            monitoring = {
              module.name = "monitoring";
              module.input = "clan-core";
              roles.client.tags.all = {};
              roles.client.extraModules = [ ../../modules/nixos/monitoring-zfs-pools.nix ];
              roles.server.machines.edi.settings.grafana.enable = true;
              roles.server.extraModules = [
                ../../modules/nixos/monitoring-server.nix
                ../../modules/nixos/monitoring-alerts.nix
                ../../modules/nixos/monitoring-teamclaude.nix
              ];
            };
          };
        };
      });
    in
      {
        inherit (clan.config) clanInternals nixosConfigurations;
        clan = clan.config;
      };
}
