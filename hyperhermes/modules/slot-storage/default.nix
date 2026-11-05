# Guest side of container slot storage (nixosModules.slot-storage), for a
# system deployed into a container slot whose host gives it storage
# (services.container-slots.storage, ../container-slots-storage).
#
# The convention: the slot's root is backed up (snapshotted on the host)
# within the slot's quota; /scratch, /var/tmp, /var/cache, /var/lib/docker,
# /var/lib/containers and /root/.cache (plus whatever else the host binds)
# are scratch: not backed up, a separate, larger quota, kept across
# restarts and deploys. Put rebuildable data (caches, build trees,
# downloaded models, experiment scratch) in scratch, everything worth
# keeping elsewhere. The host binds those paths without this module.
#
# This module adds:
#   - system-wide tool defaults (./vars.nix) that point package managers'
#     and build tools' caches into ~/.cache; `$HOME` falls back to
#     /scratch where a shell has none
#   - slotStorage.cacheUsers: those users' ~/.cache becomes a bind of
#     /scratch/home/<user>/.cache, created owned by them. Never over a
#     non-empty ~/.cache (moved or emptied by hand first: the unit says
#     so, then `systemctl restart slot-storage-cache-<user>`), and not
#     at all without a /scratch mount from the host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.slotStorage;
  vars = lib.mapAttrs (_: lib.replaceStrings [ "$HOME" ] [ "\${HOME:-/scratch}" ]) (
    import ./vars.nix
  );

  bindCache = pkgs.writeShellApplication {
    name = "slot-storage-cache";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./cache.sh;
  };
in
{
  _file = ./default.nix;

  options.slotStorage.cacheUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "agent" ];
    description = "Guest users whose ~/.cache is bound from /scratch/home/<user>/.cache (not backed up).";
  };

  config = {
    environment.variables = vars;

    assertions = map (u: {
      assertion = config.users.users ? ${u};
      message = "slotStorage.cacheUsers: no user ${u}";
    }) cfg.cacheUsers;

    systemd.services = lib.listToAttrs (
      map (
        u:
        let
          user = config.users.users.${u};
        in
        lib.nameValuePair "slot-storage-cache-${u}" {
          description = "Bind ~${u}/.cache from /scratch";
          wantedBy = [ "multi-user.target" ];
          before = [
            "systemd-user-sessions.service"
          ]
          ++ lib.optional (user.uid != null) "user@${toString user.uid}.service";
          after = [ "local-fs.target" ];
          unitConfig.RequiresMountsFor = [
            "/scratch"
            user.home
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.escapeShellArgs [
              (lib.getExe bindCache)
              u
              user.group
              user.home
            ];
          };
        }
      ) cfg.cacheUsers
    );
  };
}
