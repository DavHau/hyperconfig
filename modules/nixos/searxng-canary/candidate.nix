# searxng-candidate: the nightly bump's scratch SearXNG, run on this host
# in a sandbox instead of in the infra-space guest (a host module; the
# guest's client is the nightly bump's `nixpkgs-bump-searxng canary`,
# in infra-space's nixpkgs-bump).
#
# Why not in the guest: the candidate is unreviewed upstream master code.
# In the guest it would run as `infra`, next to the fleet push key, the
# ssh CA, API keys, ~/hyperconfig and ~/clan-secrets. Here it runs as its
# own static uid (searxng-candidate, ../vault-ids.nix ladder) with none of
# that, and through the same Mullvad egress as som's production searx
# (hyper.mullvadEgress, set on som), so the gate judges what production
# will see.
#
# Interface, like ../infra-space/gcroots.nix: the guest connects to
# /run/searxng-candidate/socket (the directory bound read-only and
# idmapped into the guest, as gcroots' is; the socket 0660 root:infra-space-gcroot, the memberless host
# group with the guest's gid) and sends one line, `<package> <rev>`:
#   <package>  the SearXNG package the guest built from the bump workspace
#              (.#nixosConfigurations.som.config.services.searx.package):
#              /nix/store/<hash>-python3.<n>-searxng-0-unstable-<date>,
#              carrying our package's marker
#              (share/searxng/stripped-requirements.txt, ../../../hyperhermes/
#              modules/browser/searxng-package.nix) and a version_frozen.py
#              naming <rev>'s first 8 characters
#   <rev>      the 40-hex `searxng` rev of the lock under test
# Nothing else is accepted: no settings (they are this host's own
# services.searx.settings, port and bind address replaced), no other
# path, and nothing is built here (no nix daemon in the sandbox). The
# guest can build any path it likes, so the name check is not what makes
# this safe; the sandbox is: whatever the package runs, it runs as an
# unprivileged uid that reaches only the internet through the tunnel.
#
# One instance at a time (MaxConnections = 1); the unit's cgroup holds
# the instance, so it dies with the request (no stale process can answer
# the next one). Before starting it the handler refuses if anything
# already listens on its address; the canary then refuses unless the
# instance's /config names this request's random instance_name and the
# expected version, and the instance must be alive before and after the
# canary. Reply: the canary's lines, then exactly one of
#   searxng-candidate: PASS | FAIL | REFUSED: <why>
#
# Loopback: the instance listens on ${address}:${port}. Off the tunnel
# its uid may open connections only to that address:port and the
# tunnel's DNS (127.0.0.153:53): hyper.mullvadEgress.tunnelOnly, a cgroup
# address filter on the unit plus an nftables rule by uid on lo (other
# ports and addresses dropped, established replies pass). So no LAN, no
# other loopback service, not production searx (127.0.0.1:8890). Any
# local process that binds the same source address can reach the
# instance while it runs (minutes, nightly); it is a search proxy over
# Mullvad, nothing more.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.searxngCanary.candidate;
  user = "searxng-candidate";
  socketDir = "/run/searxng-candidate";
  address = "127.88.99.1";
  port = 8899;
  canary = import ./package.nix { inherit pkgs; };
  settingsJson = pkgs.writeText "searxng-candidate-settings.json" (
    builtins.toJSON (
      lib.recursiveUpdate (builtins.removeAttrs config.services.searx.settings [ "redis" ]) {
        server = {
          bind_address = address;
          inherit port;
          limiter = false;
        };
      }
    )
  );

  handler = pkgs.writeShellScript "searxng-candidate" ''
    set -uo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        canary
      ]
    }
    export HOME=/tmp
    refuse() {
      echo "searxng-candidate: REFUSED: $*"
      echo "searxng-candidate: REFUSED: $*" >&2
      exit 1
    }
    line=
    IFS= read -r -t 10 -n 400 line || [ -n "$line" ] || refuse "no request (expected: <package> <rev>)"
    read -r pkg rev rest <<<"$line" || true
    [ -z "''${rest:-}" ] && [ -n "''${rev:-}" ] || refuse "expected: <package> <rev>"
    [[ $rev =~ ^[0-9a-f]{40}$ ]] || refuse "not a 40-hex rev: $rev"
    hash='[0-9a-df-np-sv-z]{32}'
    [[ $pkg =~ ^/nix/store/$hash-python3\.[0-9]+-searxng-0-unstable-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
      refuse "not a SearXNG package from upstream master: $pkg"
    [ -d "$pkg" ] && [ ! -L "$pkg" ] || refuse "no such package: $pkg"
    [ -f "$pkg/share/searxng/stripped-requirements.txt" ] || refuse "not our SearXNG package (no stripped-requirements.txt): $pkg"
    [ -x "$pkg/bin/searxng-run" ] || refuse "no bin/searxng-run in $pkg"
    frozen=$(echo "$pkg"/lib/python3.*/site-packages/searx/version_frozen.py)
    [ -f "$frozen" ] || refuse "no version_frozen.py in $pkg"
    version=$(sed -n 's/^VERSION_STRING="\([0-9.]*+[0-9a-f]\{8\}\)"$/\1/p' "$frozen")
    [ "''${version##*+}" = "''${rev:0:8}" ] || refuse "$pkg is version '$version', not rev ''${rev:0:8}"

    # Nothing may answer on the address yet: an answer would be someone
    # else's process, not this candidate.
    if (exec 3<>/dev/tcp/${address}/${toString port}) 2>/dev/null; then
      refuse "something already listens on ${address}:${toString port}"
    fi

    run=$(mktemp -d)
    nonce=$(od -vAn -N12 -tx1 /dev/urandom | tr -d ' \n')
    name="searxng-candidate-$nonce"
    jq --arg n "$name" '.general.instance_name = $n' ${settingsJson} >"$run/settings.yml"
    printf '[botdetection]\nipv4_prefix = 32\n' >"$run/limiter.toml"
    echo "searxng-candidate: $pkg ($version) as $name" >&2
    SEARXNG_SETTINGS_PATH=$run/settings.yml \
      SEARXNG_SECRET=$(od -vAn -N16 -tx1 /dev/urandom | tr -d ' \n') \
      "$pkg/bin/searxng-run" >"$run/log" 2>&1 </dev/null &
    pid=$!
    # also killed with the unit's cgroup when this script ends
    trap 'kill "$pid" 2>/dev/null' EXIT
    up=0
    for _ in $(seq 1 90); do
      kill -0 "$pid" 2>/dev/null || break
      if curl -fs -o /dev/null --max-time 2 --interface ${address} "http://${address}:${toString port}/healthz"; then
        up=1
        break
      fi
      sleep 1
    done
    if [ "$up" != 1 ]; then
      tail -n 30 "$run/log"
      echo "searxng-candidate: FAIL (the instance did not come up)"
      exit 0
    fi
    rc=0
    kill -0 "$pid" 2>/dev/null || rc=1
    if [ "$rc" = 0 ]; then
      searxng-canary --url "http://${address}:${toString port}" --source ${address} \
        --expect-instance "$name" --expect-version "$version" \
        --queries ${toString cfg.queries} --min-relevant ${toString cfg.minRelevant} \
        --min-engines ${toString cfg.minEngines} --pause 2 2>&1 || rc=$?
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      tail -n 30 "$run/log"
      echo "searxng-candidate: the instance died during the canary"
      rc=1
    fi
    if [ "$rc" = 0 ]; then
      echo "searxng-candidate: PASS"
    else
      echo "searxng-candidate: FAIL"
    fi
  '';
in
{
  options.hyper.searxngCanary.candidate = {
    enable = lib.mkEnableOption "the nightly bump's sandboxed scratch SearXNG (needs the infra-space guest and the Mullvad egress)";
    queries = lib.mkOption {
      type = lib.types.ints.between 1 6;
      default = 4;
    };
    minRelevant = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
    };
    minEngines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.hyper.infraSpace.enable or false;
        message = "hyper.searxngCanary.candidate: its only client is the infra-space guest";
      }
      {
        assertion = lib.elem "searx" config.hyper.mullvadEgress.users;
        message = "hyper.searxngCanary.candidate: searx must be Mullvad-tunneled (hyper.mullvadEgress.users): the candidate gets the same egress";
      }
    ];

    # Through the tunnel like som's searx; off it only its own listener
    # (address:port) and the tunnel's DNS (no LAN, no other loopback
    # service or port; see the header).
    hyper.mullvadEgress = {
      users = [ user ];
      dns.services = [ "searxng-candidate@" ];
      tunnelOnly."searxng-candidate@" = [ "${address}:${toString port}" ];
    };

    users.users.${user} = {
      isSystemUser = true;
      uid = 1218; # ../vault-ids.nix ladder
      group = user;
    };
    users.groups.${user}.gid = 1218;

    systemd.tmpfiles.rules = [ "d ${socketDir} 0755 root root -" ];

    systemd.sockets.searxng-candidate = {
      description = "Scratch SearXNG for the infra-space guest's nightly bump";
      wantedBy = [ "sockets.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      listenStreams = [ "${socketDir}/socket" ];
      socketConfig = {
        Accept = true;
        SocketUser = "root";
        # the guest's infra only (../infra-space/gcroots.nix)
        SocketGroup = "infra-space-gcroot";
        SocketMode = "0660";
        # one instance at a time: they share the address
        MaxConnections = 1;
        TriggerLimitIntervalSec = 0;
      };
    };

    systemd.services."searxng-candidate@" = {
      description = "Scratch SearXNG of a candidate build, with the search canary";
      serviceConfig = {
        ExecStart = handler;
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";
        User = user;
        Group = user;
        RuntimeMaxSec = "15min";
        KillMode = "control-group";
        MemoryMax = "2G";
        TasksMax = 256;
        # nixpkgs' searx unit's sandbox, plus: no view of state or
        # runtime directories at all (secrets, sockets, the guest's
        # tree under /var/lib), no nix daemon.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        PrivateIPC = true;
        PrivateMounts = true;
        TemporaryFileSystem = [
          "/var/lib:ro"
          "/var/log:ro"
          "/run:ro"
          "/srv:ro"
          "/root:ro"
        ];
        InaccessiblePaths = [
          "-/nix/var/nix/daemon-socket"
          "-/vault"
          "-/etc/ssh"
          "-/etc/secrets"
        ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged @resources"
        ];
        UMask = "0077";
      };
    };

    # the guest's end of it, bound like ../infra-space/gcroots.nix's:
    # idmapped where the guest has its own user namespace
    # (../spaces/host.nix), so the socket's host gid is the guest's infra
    # group there. A plain bindMounts entry (no idmap) shows it as
    # nobody:nogroup 0660 in the guest, and infra cannot connect.
    containers.infra-space.extraFlags = [
      "--bind-ro=${socketDir}:${socketDir}${
        lib.optionalString (config.containers.infra-space.privateUsers != "no") ":idmap"
      }"
    ];
    systemd.services."container@infra-space" = {
      wants = [ "searxng-candidate.socket" ];
      after = [ "searxng-candidate.socket" ];
    };
  };
}
