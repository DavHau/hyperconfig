/*
  Agave's tunnel on every fleet machine but the installer (the
  `agave-tunnel` importer instance in
  modules/flake-parts/nixosConfigurations.nix; docs/agave-self-hosted.md,
  H9/H10): agave's nixosModules.fleet with the tunnel only, dialing Dave's
  Agave at agave.davhau.com (the agave-host space on som,
  ./spaces/agave-host.nix) as ssh inside TLS on 443, which som's SNI router
  passes through to Agave. No desktop, no Wi-Fi (agave.wifi stays off).

    - The tunnel pins the guest's ssh host key, the public value of som's
      space-agave-host-hostkey, read from the repo (clanLib.getPublicValue,
      as ./spaces/public.nix). Before it is generated the unit is left out
      (a warning says so) and evaluation goes on.
    - Its own key is the per-machine generator `agave-tunnel` (no prompt),
      which Agave authorizes for its tunnel login once it adopts the
      machine.
    - Agave's tenant logs in as root with som's space-agave-host-tenant-ssh
      (public value from the repo, revocable by dropping it here or
      regenerating it), through ./infra-space/fleet-access.nix's key files:
      never in root's `keys` list, which other accounts copy, nor in the
      unlocking initrd. Left out while not generated. Root by design, no
      forced command: Agave deploys over the tunnel with `clan machines
      update` and runs root's shell (so no `restrict` either: that needs a
      pty). Only `from="127.0.0.1,::1"`: every tunnel ends at this
      machine's localhost:22, so the key works through a tunnel only, not
      from anywhere at the public sshds. Any local process (or ssh -L)
      on the machine can still present it, so it is only as safe as the
      private key in the agave-host guest; revoke by dropping it here.
    - sgp owns the public IPv4 som serves agave.davhau.com on, and its own
      connections to that address stay on sgp (only arriving ones are
      DNATed, ./ipv4-forward.nix): there the name resolves to som's end of
      the forwarding tunnel instead. som itself dials the public address
      (out through its uplink, back through sgp); the Agave guest admits
      only the host's veth address, so a shortcut to it would refuse som's
      other users.
    - Outbound on 443 only; no machine of the fleet filters its own
      outbound traffic beyond DNS (./encrypted-dns.nix) and its build users
      (./nix-sandbox-strict.nix).

  `hyper.agaveTunnel.reportRevision` (off, set nowhere): the hyperconfig
  commit as system.configurationRevision, which Agave's Behind column
  (agave PR #685, A4) needs to tell which commit a machine runs. Its cost:
  every commit changes the machine's toplevel, even one that changes
  nothing else (polkit restarts on each switch, a boot generation per
  no-op deploy, "deploy where the toplevel changed" and per-machine diff
  review flag it every time). Any per-commit value on the machine costs
  the same, so there is no cheaper form; turn it on per machine only once
  A4 is in the pin and the cost is wanted.
*/
{
  config,
  lib,
  pkgs,
  options,
  inputs,
  self,
  ...
}:
let
  server = "agave.davhau.com";
  publicValue =
    generator: file:
    let
      v = inputs.clan-core.clanLib.getPublicValue {
        flake = config.clan.core.settings.directory;
        machine = "som";
        inherit generator file;
        default = null;
      };
    in
    if v == null then null else lib.trim v;
  hostKey = publicValue "space-agave-host-hostkey" "ssh_host_ed25519_key.pub";
  # a path, as fleet-access.nix's: sshd reads key files at eval time
  tenantKeyFile =
    config.clan.core.settings.directory + "/vars/per-machine/som/space-agave-host-tenant-ssh/id_ed25519.pub/value";
  isGateway = (options ? hyper.ipv4Forward) && config.hyper.ipv4Forward.role == "gateway";
in
{
  imports = [ inputs.agave.nixosModules.fleet ];

  options.hyper.agaveTunnel.reportRevision = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Report the hyperconfig commit as system.configurationRevision, for Agave's Behind column (agave PR #685). Changes this machine's toplevel on every commit (the header).";
  };

  config = lib.mkMerge [
    (lib.mkIf config.hyper.agaveTunnel.reportRevision {
      # `<rev>-dirty` from an uncommitted tree
      system.configurationRevision = self.rev or self.dirtyRev or null;
    })
    {
      agave.tunnel = {
        inherit server;
        tls = true;
        # placeholder until the var exists; the unit is left out then
        hostKey = if hostKey != null then hostKey else "ssh-ed25519 not-generated-yet";
      };
      agave.desktop.enable = false;

      systemd.services.agave-tunnel.enable = hostKey != null;
      # Quiet while Agave is unreachable or doesn't list this machine yet.
      # agave's unit reruns ssh every 5 s (Restart=always, RestartSec=5,
      # no start limit), and every switch then reported "failed:
      # agave-tunnel.service": switch-to-configuration counts a service in
      # auto-restart whose last exit was non-zero as failed. Here each run
      # is one ssh session followed by a pause, then exits 0; systemd
      # reruns it 5 s later as before, so a changed tunnel still takes over
      # at the next reconnect (restartIfChanged is off upstream). The pause
      # doubles from 5 s up to 5 min (state in /run) and drops to none
      # after an attempt that lasted a minute (a session; rarely a slow
      # failure such as a connect timeout): a dropped tunnel, say Agave
      # restarting, reconnects within seconds. systemd's own RestartSteps
      # would not do: it resets only on an explicit start. The forward is
      # agave's own (template/modules/agave-tunnel.nix, `sshd`); an
      # upstream change there needs the same change here.
      systemd.services.agave-tunnel.serviceConfig.ExecStart = lib.mkForce (
        pkgs.writeShellScript "agave-tunnel" ''
          state=/run/agave-tunnel-backoff
          delay=$(cat "$state" 2>/dev/null || true)
          case "$delay" in "" | *[!0-9]*) delay=0 ;; esac
          start=$SECONDS
          rc=0
          ${config.agave.tunnel.ssh "/run/agave/infra/${config.networking.hostName}.sock:localhost:22"} || rc=$?
          if [ $((SECONDS - start)) -ge 60 ]; then delay=0; fi
          next=$((delay == 0 ? 5 : (delay * 2 > 300 ? 300 : delay * 2)))
          echo "$next" > "$state"
          echo "agave-tunnel: ssh exited with $rc, next attempt in $((delay + 5))s"
          sleep "$delay"
        ''
      );
      warnings = lib.optional (hostKey == null) "agave-tunnel: som's space-agave-host-hostkey is not generated yet; the tunnel is left out until it is.";

      # only through this machine's own tunnel (its forward ends at
      # localhost:22); toFile, not writeText: sshd reads key files at eval
      # time, a derivation would be import-from-derivation
      hyper.infraSpace.fleetAccess.extraKeyFiles = lib.optional (builtins.pathExists tenantKeyFile) (
        builtins.toFile "agave-tenant.pub" ''from="127.0.0.1,::1" ${lib.trim (builtins.readFile tenantKeyFile)}''
      );
    }
    (lib.optionalAttrs (options ? hyper.ipv4Forward) {
      networking.hosts = lib.mkIf isGateway {
        ${config.hyper.ipv4Forward.backendAddress} = [ server ];
      };
    })
  ];
}
