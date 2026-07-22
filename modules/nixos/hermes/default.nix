# Hermes Agent (NousResearch) in per-user MicroVMs — microvm.nix, fully
# declarative, qemu + slirp egress + vsock host<->guest channels.
#
# One VM per user ("hermes-<user>"); the upstream hermes NixOS module runs
# natively in each guest as an account mirroring the host user's name/uid,
# with passwordless sudo. /home/<user>/hermes is the path-identity
# exchange dir (same absolute path on both sides, also the guest HOME);
# artifacts land in /home/<user>/hermes/workspace, hermes state (.hermes
# DBs, .venv) in a root-only vault.
#
# Host <-> guest interfaces (per user):
#   - `hermes` CLI/TUI: host shim ssh-execs into the VM over vsock
#     (per-user keypair; CID = uid, owned by qemu — unsquattable).
#   - Web dashboard: root-held socket unit on 127.0.0.1:<dashboardPort>
#     -> vsock :9119 -> guest socat -> loopback :9118; fixed token auth.
#   - `hermes-desktop`: Electron app against the forwarded dashboard.
#   - spaces MCP: guest socat -> 10.0.2.2:<spacesPort> -> socket-activated
#     bridge (as the owner) -> the per-user gateway socket.
#   - secrets: per-secret systemd credentials (LoadCredential on the
#     microvm@ unit -> qemu fw_cfg -> guest PID1 -> importing unit).
# Isolation: each VM's qemu runs as its own microvm-hermes-<user> uid, so
# netfilter can tell guests apart and an escape lands in an empty
# account; owner-only key/token files + iptables OUTPUT owner-match on
# the TCP ports; loopback listeners are root-held socket units, so a
# down VM's port cannot be squatted by another local user.
#
# State vault: guest /var/lib/hermes is virtiofs from the host's
# /var/lib/hermes-microvm/<user>/state-vault/state; the 0700 root parent
# keeps the owner out.
# INVARIANT (load-bearing): the host must NEVER open the state sqlite
# DBs while a VM runs. WAL on virtiofs is safe ONLY because every
# accessor shares one guest kernel (coherent -shm page-cache mmap,
# guest-local fcntl locks); a host-side open adds a second page cache —
# the classic WAL network-fs corruption. Inspect via the guest.
#
# Layout:
#   options.nix  — option interface + assertions
#   vms.nix      — microvm.vms registration (applies guest.nix per user)
#   guest.nix    — the guest NixOS system (function: user -> ucfg -> module)
#   host.nix     — host wiring: unit drop-ins, sockets, tmpfiles, users
#   firewall.nix — iptables owner-match chain
#   cli.nix      — `hermes`/`hermes-desktop` shims + .desktop entries
#   scripts.nix  — provisioning script builders (host.nix only)
#   lib.nix      — shared names/paths/ports
#
# pip venv: see ./guest-python.nix (pinned by a flake check).
# GPU: `gpu.enable` = Vulkan via QEMU Venus on the shared host iGPU.
{ inputs, ... }:
{
  imports = [
    inputs.microvm.nixosModules.host
    ./options.nix
    ./vms.nix
    ./host.nix
    ./firewall.nix
    ./cli.nix
  ];
}
