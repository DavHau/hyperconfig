# Slot storage (part of ../container-slots.nix): every slot that opts in
# gets two ZFS datasets instead of a plain directory on the host's root
# file system:
#
#   <rootParent>/<slot>     at /var/lib/nixos-containers/<slot>, the slot's
#                           whole root tree; inherits the parent's
#                           snapshots (backed up), limited by `rootQuota`
#                           (refquota: snapshots do not count against it)
#   <scratchParent>/<slot>  at /var/lib/slot-scratch/<slot>; not
#                           snapshotted (scratchParent sits under a
#                           com.sun:auto-snapshot=false dataset), limited by
#                           `scratchQuota`
#
# One subdirectory of the scratch dataset per guest path in `scratchPaths`
# (by default /scratch, /var/tmp, /var/cache, /var/lib/docker,
# /var/lib/containers, /root/.cache) is bound over that path in the slot,
# so what the slot churns there leaves its snapshots. The guest needs no
# cooperation; nixosModules.slot (../slot) adds the tool defaults and binds
# named guest users' ~/.cache onto /scratch. Owners are guest ids, and
# stored as such: the binds are idmapped (nspawn's `:idmap`), like the
# slot's root under --private-users-ownership=auto on ZFS, so data moves
# between the two unchanged. A guest's setuid-root file is a host
# setuid-root file on disk: /var/lib/slot-scratch stays 0700.
#
# Never shadow data. Before every start, with the slot stopped, `prepare`
# creates or mounts a dataset only over an absent or empty directory. A
# slot whose root already holds data stays on its directory, without the
# scratch binds (they would hide its /var/tmp etc.), until
# `slot-storage-migrate <slot>` moves it in. The binds therefore cannot be
# static nspawn flags: prepare writes them (with the static ones from the
# containers module's /etc/nixos-containers/<slot>.conf) to an environment
# file that overrides EXTRA_NSPAWN_FLAGS for the start script, or removes
# it.
#
# Settings live in /etc/container-slots/storage.json, read at runtime, so a
# changed quota or path list does not restart a slot: quotas apply at
# switch (container-slots-storage.service), paths at the slot's next start.
# Joining or leaving (`storage.enable` of the slot) changes its unit and
# so restarts it once.
#
# Migration (operator, root), per slot:
#   slot-storage-migrate <slot> --dry-run   sizes, fit, plan; changes nothing
#   slot-storage-migrate <slot>             stop, copy the root into its
#                                           dataset, move the scratch paths'
#                                           contents into the scratch
#                                           dataset, keep the old tree at
#                                           /var/lib/nixos-containers/.premigrate-<slot>,
#                                           start it again (if it ran)
#   slot-storage-migrate --finalize <slot>  delete the old tree once verified
# It refuses when the root (minus the scratch paths) does not fit
# rootQuota, listing the largest directories: move one to scratch
# (`scratchPaths`) or raise rootQuota.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.container-slots;
  scfg = cfg.storage;
  inherit (lib) mkOption types;

  scratchDir = "/var/lib/slot-scratch";
  zfs = config.boot.zfs.package;

  # a guest path's subdirectory of the scratch dataset (as share names in
  # ../container-slots.nix)
  dirName = path: lib.removePrefix "-" (lib.replaceStrings [ "/" ] [ "-" ] path);

  defaultPaths = {
    "/scratch".mode = "1777";
    "/var/tmp".mode = "1777";
    "/var/cache".mode = "0755";
    "/var/lib/docker".mode = "0710";
    "/var/lib/containers".mode = "0700";
    "/root/.cache".mode = "0700";
  };

  participating = lib.filterAttrs (_: s: s.storage.enable) cfg.slots;
  active = scfg.enable && participating != { };

  # guest path -> { uid; gid; mode; }; an entry in scratchPaths replaces a
  # default one
  pathOf =
    slot:
    lib.mapAttrs (
      _: d:
      {
        uid = 0;
        gid = 0;
      }
      // d
    ) defaultPaths
    // slot.storage.scratchPaths;

  slotJson = name: slot: {
    root = "/var/lib/nixos-containers/${name}";
    rootDataset = "${scfg.rootParent}/${name}";
    inherit (slot.storage) rootQuota scratchQuota;
    scratch = "${scratchDir}/${name}";
    scratchDataset = "${scfg.scratchParent}/${name}";
    # stopped by the migration (the shares are partOf the slot anyway)
    units = [
      "container@${name}.service"
    ]
    ++ map (path: "container-slot-${name}-${dirName path}.service") (lib.attrNames slot.shares);
    paths = lib.mapAttrsToList (path: p: {
      inherit path;
      dir = dirName path;
      owner = p.uid;
      group = p.gid;
      inherit (p) mode;
    }) (pathOf slot);
  };

  conf = pkgs.writeText "container-slots-storage.json" (
    builtins.toJSON {
      inherit (scfg) rootParent scratchParent;
      slots = lib.mapAttrs slotJson participating;
    }
  );

  runtimeInputs = [
    zfs
    pkgs.coreutils
    pkgs.findutils
    pkgs.util-linux
    pkgs.jq
  ];

  storageTool = pkgs.writeShellApplication {
    name = "container-slot-storage";
    inherit runtimeInputs;
    text = builtins.readFile ./storage.sh;
  };

  migrateTool = pkgs.writeShellApplication {
    name = "slot-storage-migrate";
    runtimeInputs = runtimeInputs ++ [
      pkgs.rsync
      pkgs.gawk
      config.systemd.package
    ];
    text = builtins.readFile ./migrate.sh;
  };

  pathOptions = {
    options = {
      uid = mkOption {
        type = types.ints.between 0 65535;
        default = 0;
        description = "Owner of the directory, as a uid inside the slot.";
      };
      gid = mkOption {
        type = types.ints.between 0 65535;
        default = 0;
        description = "Group of the directory, as a gid inside the slot.";
      };
      mode = mkOption {
        type = types.strMatching "[0-7]{3,4}";
        default = "0755";
        description = "Mode of the directory when created (later changes inside the slot stay).";
      };
    };
  };
in
{
  options.services.container-slots = {
    storage = {
      enable = lib.mkEnableOption "ZFS datasets for the slots that opt in (`slots.<name>.storage.enable`)";
      rootParent = mkOption {
        type = types.str;
        default = "zroot/root/slots";
        description = "Parent of the slots' root datasets (created canmount=off, mountpoint=none if missing); snapshotted like its own parent.";
      };
      defaultScratchPaths = mkOption {
        type = types.listOf types.str;
        readOnly = true;
        default = lib.attrNames defaultPaths;
        description = "Guest paths every participating slot gets from its scratch dataset (owned by its root).";
      };
      scratchParent = mkOption {
        type = types.str;
        default = "zroot/root/nobackup/slots";
        description = "Parent of the slots' scratch datasets (created canmount=off, mountpoint=none if missing); its parent must exist and have com.sun:auto-snapshot=false.";
      };
      scratchDir = mkOption {
        type = types.str;
        readOnly = true;
        default = scratchDir;
        description = "Where the scratch datasets are mounted: <scratchDir>/<slot>.";
      };
    };

    slots = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.storage = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Give this slot its root and scratch datasets (with services.container-slots.storage.enable). A root that already holds data stays as it is until `slot-storage-migrate <slot>`.";
            };
            rootQuota = mkOption {
              type = types.nullOr types.str;
              default = "20G";
              example = "120G";
              description = "refquota of the slot's root dataset (backed up); null: none.";
            };
            scratchQuota = mkOption {
              type = types.nullOr types.str;
              default = "200G";
              description = "quota of the slot's scratch dataset; null: none.";
            };
            scratchPaths = mkOption {
              type = types.attrsOf (types.submodule pathOptions);
              default = { };
              example = {
                "/home/agent/.cache" = {
                  uid = 1000;
                  gid = 100;
                  mode = "0700";
                };
              };
              description = ''
                Guest paths served from the scratch dataset, on top of
                ${lib.concatStringsSep ", " (lib.attrNames defaultPaths)}
                (owned by the slot's root; an entry here overrides one of
                them). Owner and group are ids inside the slot.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.enable && active) {
    assertions = lib.mapAttrsToList (name: slot: {
      assertion =
        let
          dirs = map dirName (lib.attrNames (pathOf slot));
        in
        lib.length dirs == lib.length (lib.unique dirs)
        && lib.all (p: lib.hasPrefix "/" p && !lib.hasInfix ".." p && !lib.hasInfix "//" p) (
          lib.attrNames (pathOf slot)
        );
      message = "services.container-slots.slots.${name}.storage.scratchPaths: paths must be absolute, without '..' or '//', and distinct after '/' -> '-'";
    }) participating;

    boot.supportedFilesystems = [ "zfs" ];
    environment.etc."container-slots/storage.json".source = conf;
    environment.systemPackages = [ migrateTool ];

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (
        name: _:
        lib.nameValuePair "container@${name}" {
          # Before the symlink checks of container-slots' prep (an
          # ExecStartPre): they look into the root, which must be the
          # dataset by then. Pulled in again at every start: a oneshot
          # without RemainAfterExit is inactive once done.
          requires = [ "container-slot-storage@${name}.service" ];
          after = [ "container-slot-storage@${name}.service" ];
          # The containers module's own file, then the one prepare writes
          # (later files win: EXTRA_NSPAWN_FLAGS with the scratch binds).
          serviceConfig.EnvironmentFile = lib.mkForce [
            "-/etc/nixos-containers/%i.conf"
            "-/run/container-slots/%i/storage.env"
          ];
        }
      ) participating)
      {
        # Its own unit, not an ExecStartPre of container@<slot>: that
        # unit's device policy (the slot's) keeps /dev/zfs closed even to
        # a privileged ("+") command.
        "container-slot-storage@" = {
          description = "Datasets of container slot %i";
          after = [ "zfs-mount.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe storageTool} prepare %i";
          };
        };
        # Quotas of existing datasets, at boot and whenever they change.
        container-slots-storage = {
          description = "Quotas of the container slots' datasets";
          wantedBy = [ "multi-user.target" ];
          after = [ "zfs-mount.service" ];
          restartTriggers = [ conf ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${lib.getExe storageTool} quotas";
          };
        };
      }
    ];
  };
}
