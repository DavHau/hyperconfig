# Distributed nix builds between clan machines.
#
# roles.builder: accepts builds as the unprivileged `nixremote` user.
#   Clients are authenticated by ssh key and their store paths by nix
#   signing key — both read from the clients' in-repo public vars.
#   Deliberately NO nix.settings.trusted-users: an untrusted caller can
#   only import paths signed by a key in trusted-public-keys.
# roles.client: generates ssh + signing keypairs (clan vars), signs every
#   locally-registered path (secret-key-files), and exposes the builders
#   through a runtime-switchable machines file:
#     nix.buildMachines -> /etc/nix/machines (NixOS-rendered)
#     builders = @/run/remote-builders/machines
#     remote-builders.service copies (start) / truncates (stop) it.
#   Members of wheel may flip the unit without a password (polkit).
{ clanLib, ... }:
{
  _class = "clan.service";
  manifest.name = "hyperconfig/remote-building";
  manifest.description = "Offload nix builds to builder machines over ssh; keys and signatures via clan vars";
  manifest.categories = [ "System" ];

  roles.builder = {
    description = "Accepts builds from the client machines as the unprivileged nixremote user.";

    interface =
      { lib, ... }:
      {
        options = {
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname clients connect to. Default: <machineName>.d (clan domain).";
          };
          maxJobs = lib.mkOption {
            type = lib.types.int;
            default = 10;
            description = "Max parallel builds a client schedules here.";
          };
          speedFactor = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "Relative speed vs the client (higher = preferred).";
          };
          systems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "x86_64-linux" "aarch64-linux" ];
            description = "Systems this builder accepts.";
          };
          supportedFeatures = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "nixos-test" "big-parallel" "kvm" "benchmark" ];
            description = "Features advertised to clients.";
          };
        };
      };

    perInstance =
      { instanceName, roles, ... }:
      {
        nixosModule =
          { config, lib, ... }:
          let
            # Public var of one client machine; null until its vars are
            # generated so the builder still evaluates on a fresh checkout.
            clientVals =
              file:
              lib.filter (v: v != null) (
                map (
                  machine:
                  clanLib.getPublicValue {
                    flake = config.clan.core.settings.directory;
                    generator = "remote-building-${instanceName}";
                    inherit machine file;
                    default = null;
                  }
                ) (lib.attrNames (roles.client.machines or { }))
              );
          in
          {
            services.openssh.enable = true;

            users.groups.nixremote = { };
            users.users.nixremote = {
              isNormalUser = true;
              group = "nixremote";
              # The ssh store protocol runs `nix-store --serve` through the
              # login shell; nologin would break it.
              useDefaultShell = true;
              openssh.authorizedKeys.keys = map lib.trim (clientVals "ssh.id.pub");
            };

            # Accept client-signed store paths. NOT trusted-users: this is
            # the whole point — an untrusted user may only import paths
            # carrying a signature the daemon already trusts.
            nix.settings.trusted-public-keys = map lib.trim (clientVals "signing.key.pub");
          };
      };
  };

  roles.client = {
    description = "Offloads builds to the builder machines; bar toggle optional.";

    interface =
      { lib, ... }:
      {
        options.barToggle = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Seed the noctalia CustomButton that toggles remote-builders.service.";
        };
      };

    perInstance =
      {
        instanceName,
        roles,
        settings,
        ...
      }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            gen = config.clan.core.vars.generators."remote-building-${instanceName}";
            machineName = config.clan.core.settings.machine.name;
          in
          {
            imports = lib.optional settings.barToggle ../../nixos/noctalia-remote-build;

            clan.core.vars.generators."remote-building-${instanceName}" = {
              files."ssh.id" = { };            # secret, deployed (defaults)
              files."ssh.id.pub".secret = false;
              files."signing.key" = { };       # secret, deployed
              files."signing.key.pub".secret = false;
              runtimeInputs = [
                pkgs.openssh
                pkgs.nix
              ];
              script = ''
                ssh-keygen -t ed25519 -N "" \
                  -C "${machineName}-remote-building-${instanceName}" \
                  -f "$out"/ssh.id
                nix key generate-secret \
                  --key-name "${machineName}-remote-building-${instanceName}-1" \
                  > "$out"/signing.key
                nix key convert-secret-to-public \
                  < "$out"/signing.key > "$out"/signing.key.pub
              '';
            };

            # Sign every path this machine registers, so builders accept
            # them without trusting the connection itself.
            nix.settings.secret-key-files = [ gen.files."signing.key".path ];

            nix.distributedBuilds = true;
            nix.settings.builders-use-substitutes = true;

            # NixOS renders these into /etc/nix/machines; the toggle unit
            # decides whether the daemon sees them (builders = @/run/...).
            nix.buildMachines = lib.mapAttrsToList (name: machine: {
              hostName = if machine.settings.host != null then machine.settings.host else "${name}.d";
              protocol = "ssh";
              sshUser = "nixremote";
              sshKey = gen.files."ssh.id".path;
              inherit (machine.settings)
                systems
                maxJobs
                speedFactor
                supportedFeatures
                ;
            }) (roles.builder.machines or { });

            # nix tolerates an empty @file but the unit must never race a
            # missing one at boot.
            systemd.tmpfiles.rules = [
              "d /run/remote-builders 0755 root root -"
              "f /run/remote-builders/machines 0444 root root -"
            ];
            nix.settings.builders = "@/run/remote-builders/machines";

            systemd.services.remote-builders = {
              description = "Expose remote nix builders to the daemon (stop = build locally)";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.coreutils}/bin/install -m 0444 /etc/nix/machines /run/remote-builders/machines";
                ExecStop = "${pkgs.coreutils}/bin/install -m 0444 /dev/null /run/remote-builders/machines";
              };
            };

            security.polkit.extraConfig = ''
              polkit.addRule(function(action, subject) {
                if (action.id == "org.freedesktop.systemd1.manage-units" &&
                    action.lookup("unit") == "remote-builders.service" &&
                    subject.isInGroup("wheel")) {
                  return polkit.Result.YES;
                }
              });
            '';
          };
      };
  };
}
