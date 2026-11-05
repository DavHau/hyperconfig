/*
  Per-user ZFS datasets: a backed-up home with a hard limit and a larger
  scratch space that is not snapshotted
  (docs/superpowers/specs/2026-11-05-som-entity-storage-design.md).

    <dataset>/home/<u>                    /home/<u>              refquota homeQuota
    <nobackup>/scratch/<u>                /home/<u>/scratch      quota scratchQuota (subtree)
    <nobackup>/scratch/<u>/cache          /home/<u>/.cache
    <nobackup>/scratch/<u>/containers     /home/<u>/.local/share/containers
    <nobackup>/scratch/<u>/sbox-state     /home/<u>/.local/state/sbox

  Snapshots follow com.sun:auto-snapshot, inherited: the homes from
  <dataset>, scratch from <nobackup> (off). Only the users listed in
  `users` are managed, so they can be moved over one at a time.

  entity-storage.service reconciles at boot (before tmpfiles and any
  login, user manager or agent unit) and on every switch that changes the
  config. It creates or mounts a dataset only over an absent or empty
  directory, so a newly listed user with an existing home is refused
  (logged, unit fails) until `entity-storage-migrate <user>` moved the
  home onto its datasets.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.entityStorage;
  quotaType = lib.types.strMatching "[0-9]+[KMGTP]?";
  homesDir = "/home";

  configFile = pkgs.writeText "entity-storage.json" (
    builtins.toJSON {
      homeParent = "${cfg.dataset}/home";
      inherit homesDir;
      scratchParent = "${cfg.nobackupDataset}/scratch";
      users = lib.mapAttrs (name: u: {
        inherit (config.users.users.${name}) home group;
        homeQuota = if u.homeQuota != null then u.homeQuota else cfg.defaults.homeQuota;
        scratchQuota = if u.scratchQuota != null then u.scratchQuota else cfg.defaults.scratchQuota;
      }) cfg.users;
    }
  );

  inputs = [
    config.boot.zfs.package
    config.systemd.package
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gnused
    pkgs.jq
    pkgs.procps
    pkgs.util-linux
  ];

  reconcile = pkgs.writeShellApplication {
    name = "entity-storage-reconcile";
    runtimeInputs = inputs;
    runtimeEnv.ENTITY_STORAGE_CONFIG = configFile;
    text = builtins.readFile ./common.sh + builtins.readFile ./reconcile.sh;
  };

  migrate = pkgs.writeShellApplication {
    name = "entity-storage-migrate";
    runtimeInputs = inputs ++ [
      pkgs.rsync
      reconcile
    ];
    runtimeEnv.ENTITY_STORAGE_CONFIG = configFile;
    text = builtins.readFile ./common.sh + builtins.readFile ./migrate.sh;
  };
in
{
  options.hyper.entityStorage = {
    enable = lib.mkEnableOption "per-user home and scratch datasets";
    dataset = lib.mkOption {
      type = lib.types.str;
      default = "zroot/root";
      description = "Snapshotted dataset the homes go under (as <dataset>/home/<user>).";
    };
    nobackupDataset = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.dataset}/nobackup";
      defaultText = lib.literalExpression ''"''${dataset}/nobackup"'';
      description = "Existing dataset with snapshots off; scratch goes under it (as <nobackupDataset>/scratch/<user>).";
    };
    defaults = {
      homeQuota = lib.mkOption {
        type = quotaType;
        default = "20G";
        description = "refquota of a home dataset.";
      };
      scratchQuota = lib.mkOption {
        type = quotaType;
        default = "200G";
        description = "quota of a scratch dataset and its children.";
      };
    };
    users = lib.mkOption {
      default = { };
      description = "The managed users (normal accounts with their home at /home/<name>).";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            homeQuota = lib.mkOption {
              type = lib.types.nullOr quotaType;
              default = null;
              description = "refquota of the home; null: defaults.homeQuota.";
            };
            scratchQuota = lib.mkOption {
              type = lib.types.nullOr quotaType;
              default = null;
              description = "quota of scratch; null: defaults.scratchQuota.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (
      name: _:
      let
        u = config.users.users.${name} or null;
      in
      {
        assertion = u != null && u.isNormalUser && u.home == "${homesDir}/${name}";
        message = "hyper.entityStorage.users.${name}: needs a normal user ${name} with home ${homesDir}/${name}";
      }
    ) cfg.users;

    environment.systemPackages = [ migrate ];

    systemd.services.entity-storage = {
      description = "Per-user home and scratch datasets";
      # Early, so tmpfiles, logins, user managers and the users' services
      # (hermes-agent-<user>, ...) all find the datasets mounted. Users
      # exist by then: the activation script creates them.
      wantedBy = [ "sysinit.target" ];
      after = [
        "zfs-import.target"
        "zfs-mount.service"
        "local-fs.target"
      ];
      before = [
        "sysinit.target"
        "systemd-tmpfiles-setup.service"
        "systemd-user-sessions.service"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The config is in the script: a changed config restarts the unit
        # on switch.
        ExecStart = lib.getExe reconcile;
        TimeoutStartSec = "5min";
      };
    };
  };
}
