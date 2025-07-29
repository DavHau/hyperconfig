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
  flake.clan = (inputs.clan-core.lib.clan {
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
      };
      services = {
        importer.base = {
          roles.default.tags = ["all"];
          roles.default.extraModules = [
            inputs.clan-core.clanModules.static-hosts
            ../../modules/nixos/common.nix
          ];
        };
        zerotier.zt-home = {
          roles.peer.tags = [ "all" ];
          roles.controller.machines = [ "nas" ];
          # roles.moon.machines = [ "nas" ];
        };
      };

      # NEW API
      instances = {
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
          roles.client.machines.amy = {};
          roles.client.settings.exclude = import ../backup-exclude.nix;
          roles.server.settings.directory = "/pool11/enc/clan-backup";
        };
        dave = {
          module.name = "easytier";
          module.input = "self";
          roles.peer.settings.domain = "dave";
          roles.peer.tags.all = {};
        };
        sshd = {
          module.name = "sshd";
          module.input = "clan-core";
          roles.server.tags.all = {};
          roles.client.tags.all = {};
        };
      };
    };
  }).config;
}
