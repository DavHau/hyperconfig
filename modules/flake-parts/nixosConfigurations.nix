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
        };

        specialArgs = {
          inherit inputs pkgsCross self;
        };

        meta.name = "DavClan";

        modules = {
          nix-cache = ../../modules/clan/nix-cache;
          easytier = ../../modules/clan/easytier;
        };

        # add machines to their hosts
        inventory = {
          machines = {
            bam.tags = [ "wifi-home"];
            installer.tags = [ "wifi-home" ];
            cm-pi.tags = [ "wifi-home" ];
            joy.deploy.targetHost = "joy.dave";
          };

          # NEW API
          instances = {
            admin = {
              roles.default.tags.all = { };
              roles.default.settings.allowedKeys = {
                # Insert the public key that you want to use for SSH access.
                # All keys will have ssh access to all machines ("tags.all" means 'all machines').
                # Alternatively set 'users.users.root.openssh.authorizedKeys.keys' in each machine
                "dave" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuhpzDHBPvn8nv8RH1MRomDOaXyP4GziQm7r3MZ1Syk";
              };
            };
            zt-home = {
              module.name = "zerotier";
              roles.peer.tags.all = {};
              roles.controller.machines.nas = {};
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
            dave-cache = {
              module.name = "nix-cache";
              module.input = "self";
              roles.server.machines.bam = {};
              roles.server.settings.priority = 41;
              roles.client.tags.all = {};
            };
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
              roles.client.tags.all = {};
            };

            # VPNs
            wireguard = {
              roles.controller = {
                machines.edi = {};
                settings = {
                  # Public endpoint where this controller can be reached
                  endpoint = "wg.davhau.com";
                  # Optional: Change the UDP port (default: 51820)
                  port = 51820;
                };
              };
              roles.peer = {
                machines.bam = {};
              };
            };
            # easytier
            dave = {
              module.name = "easytier";
              module.input = "self";
              # roles.peer.settings.domain = "dave";
              roles.peer.settings.foreignHostNames = [
                "ashburn1"
                "nuremberg1"
              ];
              roles.peer.tags.all = {};
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
