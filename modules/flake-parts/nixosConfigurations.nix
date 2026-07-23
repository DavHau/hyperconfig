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
          # nixos-example's hermes.nix (imported by v-machine via path, so
          # it resolves `inputs` from OUR specialArgs) needs
          # inputs.hermes-agent; the root flake dropped that input when
          # hermes moved into the spaces flake — alias spaces' pin instead
          # of re-locking our own.
          inputs = inputs // { hermes-agent = inputs.spaces.inputs.hermes-agent; };
          inherit pkgsCross self;
        };

        meta.name = "DavClan";
        meta.domain = "d";

        modules = {
          nix-cache = ../../modules/clan/nix-cache;
          # easytier = ../../modules/clan/easytier;
          wireguard = ../../modules/clan/wireguard;
          ncps = inputs.ncps + "/clanServices/ncps";
          monitoring = inputs.clan-core-monitoring + "/modules/monitoring";
          cctl = ../../modules/clan/cctl;
          remote-building = ../../modules/clan/remote-building;
        };

        # add machines to their hosts
        inventory = {
          machines = {
            installer.tags = [ "wifi-home" ];
            cm-pi.tags = [ "wifi-home" ];
            # joy.deploy.targetHost = "joy.dave";
          };

          instances = {
            admin = {
              roles.default.tags = {
                all = {  };
              };
              roles.default.settings = {
                allowedKeys = {
                  dave = "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBMAWEy2KMRae6D0kreSie2gA7s3g8x3QVNtdotxY4MDVO2dim6kc1OlGovByt06XGa/H1kMwIlc+RhfuJ/eRioGhrJ13SrDeJegC0T1iyIIZY67WMNSj5vZ0bJOmIQvm1A== grmpf@amy";
                };
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
            zt-eu = {
              module.name = "zerotier";
              roles.peer.tags.all = {};
              roles.controller.machines.edi = {};
              roles.controller.settings.allowedIps = [
                "7c29125877"
              ];
            };
            # VibePN mesh: instance name = network name; the service module
            # mints the shared invite phrase (generator vibepn-vibe) and
            # enables services.vibepn on every peer. Port/firewall settings
            # live in modules/nixos/vibepn.nix on the member machines.
            vibe = {
              module.name = "vibepn";
              module.input = "vibepn";
              roles.peer.machines.amy = {};
              roles.peer.machines.bam = {};
              roles.peer.machines.edi = {};
            };
            importer.roles.default.extraModules = [
              ../../modules/nixos/common.nix
            ];
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
            # dave-cache = {
            #   module.name = "nix-cache";
            #   module.input = "self";
            #   roles.server.machines.bam = {};
            #   roles.server.settings.priority = 41;
            #   roles.client.tags.all = {};
            # };
            # TODO: enable backups again
            # dave-backup = {
            #   module.name = "borgbackup";
            #   module.input = "clan-core";
            #   roles.server.machines.nas = {};
            #   roles.client.machines.amy = {};
            #   roles.client.settings.exclude = import ../backup-exclude.nix;
            #   roles.server.settings.directory = "/pool11/enc/clan-backup";
            # };
            sshd = {
              module.name = "sshd";
              module.input = "clan-core";
              roles.server.tags.all = {};
              roles.server.settings.authorizedKeys = {
                "dave" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk";
                "phone" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJwzL0rt4J+kzggV4pFXf9yh9zBF6n4hdXXVbCB7p1x6";
              };
              roles.client.tags.all = {};
            };
            remote-building = {
              module.name = "remote-building";
              module.input = "self";
              roles.builder.machines.bam = {};
              roles.client.machines.amy.settings.barToggle = true;
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
                "amy" "bam" "cat" "cm-pi" "joy" "nas"
                "tossa-pi" "vit" "v-machine" "installer"
              ] (_: { });
            };
            # easytier
            # dave = {
            #   module.name = "easytier";
            #   module.input = "self";
            #   # roles.peer.settings.domain = "dave";
            #   roles.peer.settings.foreignHostNames = [
            #     "ashburn1"
            #     "nuremberg1"
            #   ];
            #   roles.peer.tags.all = {};
            # };

            # ncps = {
            #   module.name = "ncps";
            #   module.input = "self";
            #   roles.server.machines.bam = {
            #     settings.caches = [
            #       "https://cache.nixos.org"
            #       "https://cache.clan.lol"
            #     ];
            #     settings.publicKeys = [
            #       "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
            #       "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
            #     ];
            #   };
            #   roles.client.machines.amy = {};
            #   roles.client.machines.bam = {};
            # };

            # monitoring = {
            #   module.name = "monitoring";
            #   module.input = "clan-core-monitoring";
            #   # roles.server.machines.bam = {};
            #   roles.server.settings = {
            #     grafana.enable = true;
            #   };
            #   # roles.client.tags = ["all"];
            # };
          };
        };
      });
    in
      {
        inherit (clan.config) clanInternals nixosConfigurations;
        clan = clan.config;
      };
}
