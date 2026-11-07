# The system inside a container slot (nixosModules.slot; also exported by
# hyperconfig's flake): everything a slot guest needs from the host side's
# conventions (../container-slots.nix, ../container-slots-storage), so a
# deployer imports this and writes only their own content. The slots'
# bootstrap system is built from it too.
#
# Sets:
#   - boot.isNspawnContainer = true
#   - sshd, letting root in with the keys the host bind-mounts read-only
#     at /var/lib/container-slot/authorized_keys at every start (appended
#     to services.openssh.authorizedKeysFiles; the guest's own keys work
#     as well). Without sshd and a key, the deployer is locked out, and
#     the host does not repair that.
#   - the slot's ssh host key: the one the host keeps (and pins) at
#     /var/lib/container-slot/ssh_host_ed25519_key (mkDefault), so it
#     survives resets and redeploys.
#
# Not set, because the host provides it and a guest must not: addresses,
# routes, DNS (resolv.conf is copied in at every start).
#
# Storage (with the host's services.container-slots.storage): the slot's
# root is backed up (snapshotted on the host) within the slot's quota;
# /scratch, /var/tmp, /var/cache, /var/lib/docker, /var/lib/containers and
# /root/.cache (plus whatever else the host binds) are scratch: not backed
# up, a separate, larger quota, kept across restarts and deploys. Put
# rebuildable data (caches, build trees, downloaded models, experiment
# scratch) in scratch, everything worth keeping elsewhere. The host binds
# those paths without this module. This module adds:
#   - system-wide tool defaults (./vars.nix) that point package managers'
#     and build tools' caches into ~/.cache; `$HOME` falls back to
#     /scratch where a shell has none
#   - containerSlot.cacheUsers: those users' ~/.cache becomes a bind of
#     /scratch/home/<user>/.cache, created owned by them. Never over a
#     non-empty ~/.cache (moved or emptied by hand first: the unit says
#     so, then `systemctl restart container-slot-cache-<user>`), and not
#     at all without a /scratch mount from the host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.containerSlot;
  vars = lib.mapAttrs (_: lib.replaceStrings [ "$HOME" ] [ "\${HOME:-/scratch}" ]) (
    import ./vars.nix
  );

  bindCache = pkgs.writeShellApplication {
    name = "container-slot-cache";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./cache.sh;
  };
in
{
  _file = ./default.nix;

  options.containerSlot.cacheUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "agent" ];
    description = "Guest users whose ~/.cache is bound from /scratch/home/<user>/.cache (not backed up).";
  };

  config = {
    boot.isNspawnContainer = true;

    services.openssh = {
      enable = true;
      authorizedKeysFiles = [ "/var/lib/container-slot/authorized_keys" ];
      hostKeys = lib.mkDefault [
        {
          type = "ed25519";
          path = "/var/lib/container-slot/ssh_host_ed25519_key";
        }
      ];
    };

    environment.variables = vars;

    assertions = map (u: {
      assertion = config.users.users ? ${u};
      message = "containerSlot.cacheUsers: no user ${u}";
    }) cfg.cacheUsers;

    systemd.services = lib.listToAttrs (
      map (
        u:
        let
          user = config.users.users.${u};
        in
        lib.nameValuePair "container-slot-cache-${u}" {
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
