/*
  GC roots on this host for systems built from the infra-space guest
  (a host module, imported by ./default.nix; the guest's client is
  `infra-space-gcroot`, ./guest.nix).

  The problem: the guest builds through this host's nix-daemon, and the
  daemon registers the guest's `nix build` result links as indirect roots
  in gcroots/auto under the guest's paths (/home/infra/..., /var/lib/...),
  which do not exist here. Nix's GC and fast-nix-gc (../fast-nix-gc.nix)
  take those for dangling and delete them: nothing the guest built was
  protected beyond fast-nix-gc's --keep-recent day. A cross build of cm-pi
  (~6 h from source) was lost every night.

  The fix: a narrow root-owned interface. The guest connects to
  /run/infra-space-gcroots/socket (its directory bound into the guest
  read-only; the socket is 0660 root:infra-space-gcroot, a host group
  with the guest's infra gid and no members)
  and sends one line, `<machine> <drv>`. A socket-activated instance
  (Accept=yes) of infra-space-gcroot@.service, as root, accepts it only if
  <machine> is one of `gcRoots.machines` and <drv> is
  /nix/store/<hash>-nixos-system-<machine>-<version>.drv, a valid store path
  whose output is built. It roots, in /nix/var/nix/gcroots/infra-space/<machine>/:
    current    -> the system (its runtime closure)
    previous   -> the system rooted before it (rollback / the last good
                  one while a newer main is not deployed yet)
    closure/   one link per path of `nix-store -qR --include-outputs <drv>`
                  (the build closure: build-only toolchains, sources, .drvs),
                  only for `gcRoots.closureMachines` (cm-pi) and only for
                  `current`: the next cross build reuses the unchanged part.
  Re-rooting the same system keeps `previous`; a new one moves `current`
  to `previous` and drops the old `previous` (and the old closure). Each
  request takes nix's gc.lock shared (as nix does while adding temp roots),
  so no collection runs between the validity check and the links.

  Why this and not the alternatives: making the guest's root paths
  resolvable here (symlinks from this host's /home/infra and /var/lib/hermes
  into the container's tree) would root whatever any guest process links
  anywhere, with no bound, through host paths a guest user controls, and
  fast-nix-gc deliberately resolves only one hop; a host timer evaluating
  main itself would need a checkout, an eval of every machine (~6 GiB per
  full eval) and would root main before anything is built. Here the guest
  names a built derivation whose name looks like a known machine's system
  (the name is all that is checked): at most current+previous per machine
  and one build closure, of whatever size it built. The worst it can do is
  replace a machine's roots, which `infra` (root on every fleet machine)
  could anyway. A flood of connections is bounded by MaxConnections (the
  socket's trigger limit is off, so it can't leave the socket failed). No global keep-outputs/keep-derivations: that would keep
  the build closure of every root on this host, tenants' included.

  Disk: per machine its runtime closure twice at most (mostly shared with
  this host's own system), plus cm-pi's build closure, ~64 GiB (14k paths,
  2026-11; runtime 4.6 GiB). A bump that moves the stdenv frees the old
  closure only once the new one is rooted, so ~2x during that build.

  Machines dropped from `gcRoots.machines` keep their directory: remove it
  by hand (`rm -r /nix/var/nix/gcroots/infra-space/<machine>`).

  Superseded on som: /nix/var/nix/gcroots/infra-cm-pi and infra-cm-pi-new,
  hand-made roots of cm-pi's build closures (14k links each). Once
  /nix/var/nix/gcroots/infra-space/cm-pi/closure exists (the first
  Saturday bump after this deploy, or `infra-space-gcroot cm-pi <result>`
  by hand), root removes it: `rm -r /nix/var/nix/gcroots/infra-cm-pi{,-new}`;
  the next GC frees what the new closure no longer shares.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.infraSpace;
  rootsDir = "/nix/var/nix/gcroots/infra-space";
  socketDir = "/run/infra-space-gcroots";
  # the guest's infra group (./default.nix, uid); no host group has it
  guestGid = config.containers.infra-space.config.users.groups.infra.gid;
  # The guest's gid named on this host, for the socket's group: no
  # members, so no host user or service gets it (it already owns the
  # guest's home here, ./default.nix).
  socketGroup = "infra-space-gcroot";

  handler = pkgs.writeShellScript "infra-space-gcroot" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.util-linux
        config.nix.package
      ]
    }
    # every nix query through the daemon (root is trusted there): this
    # unit's sandbox keeps the store and its database read-only
    export NIX_REMOTE=daemon
    umask 022
    refuse() {
      echo "refused: $*"
      echo "infra-space-gcroot: refused: $*" >&2
      exit 1
    }
    machines=" ${lib.concatStringsSep " " cfg.gcRoots.machines} "
    closureMachines=" ${lib.concatStringsSep " " cfg.gcRoots.closureMachines} "

    line=
    IFS= read -r -t 10 -n 600 line || [ -n "$line" ] || refuse "no request (expected: <machine> <drv>)"
    read -r machine drv rest <<<"$line" || true
    [ -z "''${rest:-}" ] && [ -n "''${drv:-}" ] || refuse "expected: <machine> <drv>"
    [[ $machine =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && [[ $machines == *" $machine "* ]] ||
      refuse "unknown machine (known:$machines)"
    # the machine's own system: nixos-system-<machine>-<version>.drv, the
    # version starting with a digit (so cm's never passes for cm-pi's)
    hash='[0-9a-df-np-sv-z]{32}'
    [[ $drv =~ ^/nix/store/$hash-nixos-system-$machine-[0-9][0-9A-Za-z+._?=-]*\.drv$ ]] ||
      refuse "not a nixos system derivation of $machine: $drv"

    install -d -m 0755 ${rootsDir}
    # one request at a time, and no collection until the links are in
    exec 8>${rootsDir}/.lock
    flock 8
    exec 9</nix/var/nix/gc.lock
    flock -s -w 7200 9 || refuse "timed out waiting for a running garbage collection"

    nix-store --check-validity "$drv" 2>/dev/null || refuse "no such derivation in the store: $drv"
    out=$(nix-store -q --outputs "$drv") || refuse "cannot query the outputs of $drv"
    [[ $out != *$'\n'* && $out =~ ^/nix/store/$hash-nixos-system-$machine-[^/]*$ ]] || refuse "unexpected outputs of $drv"
    nix-store --check-validity "$out" 2>/dev/null || refuse "not built: $out"

    dir=${rootsDir}/$machine
    install -d -m 0755 "$dir"
    cur=$(readlink "$dir/current" || true)
    if [ "$cur" != "$out" ]; then
      if [ -n "$cur" ]; then
        ln -sfn "$cur" "$dir/.previous.new"
        mv -T "$dir/.previous.new" "$dir/previous"
      fi
      ln -sfn "$out" "$dir/.current.new"
      mv -T "$dir/.current.new" "$dir/current"
    fi
    find "$dir" -mindepth 1 -maxdepth 1 -name '.closure.*' -exec rm -rf {} +
    msg="ok $machine: current $out, previous $(readlink "$dir/previous" || echo none)"
    if [[ $closureMachines == *" $machine "* ]]; then
      tmp=$(mktemp -d "$dir/.closure.XXXXXX")
      nix-store -qR --include-outputs "$drv" | xargs -r ln -s -t "$tmp"
      chmod 0755 "$tmp"
      rm -rf "$dir/closure"
      mv -T "$tmp" "$dir/closure"
      msg="$msg, build closure $(find "$dir/closure" -mindepth 1 -maxdepth 1 | wc -l) paths"
    else
      rm -rf "$dir/closure"
    fi
    echo "$msg"
    echo "infra-space-gcroot: $msg" >&2
  '';
in
{
  options.hyper.infraSpace.gcRoots = {
    machines = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9-]{0,62}");
      default = lib.remove "installer" (
        lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ../../../machines))
      );
      defaultText = lib.literalMD "every directory in machines/ but `installer` (its images are what gets used, never its system)";
      description = "Machines whose systems the guest may root on this host (./gcroots.nix).";
    };
    closureMachines = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cm-pi" ];
      description = "Machines whose current system keeps its whole build closure (`nix-store -qR --include-outputs`), build-only paths included: the slow cross builds.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (m: lib.elem m cfg.gcRoots.machines) cfg.gcRoots.closureMachines;
        message = "hyper.infraSpace.gcRoots.closureMachines must be in gcRoots.machines";
      }
      {
        assertion =
          config.users.groups.${socketGroup}.members == [ ]
          && lib.all (u: u.group != socketGroup && !(lib.elem socketGroup u.extraGroups)) (
            lib.attrValues config.users.users
          );
        message = "users.groups.${socketGroup}: no host user (nor a unit's Group=/SupplementaryGroups=) may be in it (it is the infra-space guest's gid)";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${rootsDir} 0755 root root -"
      "d ${socketDir} 0755 root root -"
      # the handler's lock against a collection (nix creates it on first
      # use; the handler's sandbox cannot)
      "f /nix/var/nix/gc.lock 0600 root root -"
    ];

    users.groups.${socketGroup}.gid = guestGid;

    systemd.sockets.infra-space-gcroot = {
      description = "GC roots for the infra-space guest's builds";
      wantedBy = [ "sockets.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      listenStreams = [ "${socketDir}/socket" ];
      socketConfig = {
        Accept = true;
        # connecting takes write access: root and the guest's infra only
        # (the group below; systemd resolves SocketGroup by name)
        SocketUser = "root";
        SocketGroup = socketGroup;
        SocketMode = "0660";
        MaxConnections = 4;
        # a flooding guest would trip systemd's trigger limit and leave the
        # socket failed; with the limit off, MaxConnections is the bound
        TriggerLimitIntervalSec = 0;
      };
    };
    systemd.services."infra-space-gcroot@" = {
      description = "Root an infra-space guest's build";
      serviceConfig = {
        ExecStart = handler;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        # a collection may hold gc.lock for an hour (the wait above)
        RuntimeMaxSec = "3h";
        ProtectSystem = "strict";
        ReadWritePaths = [ rootsDir ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        SystemCallFilter = [ "@system-service" ];
      };
    };

    # the guest's end of it
    containers.infra-space.bindMounts.${socketDir} = {
      hostPath = socketDir;
      isReadOnly = true;
    };
    systemd.services."container@infra-space" = {
      wants = [ "infra-space-gcroot.socket" ];
      after = [ "infra-space-gcroot.socket" ];
    };
  };
}
