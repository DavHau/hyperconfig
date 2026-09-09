# momentum's vault directory for its hermes agent (som only).
#
# momentum's datasets live on bam at /vault/parquet/momentum (vault-ids.nix).
# The host bind-mounts that directory read-only into the hermes exchange dir
# as /home/momentum/hermes/state, so everything momentum keeps in the
# exchange dir (repos, workspace) can point at it with a relative symlink.
# The agent now runs natively (momentum-hermes.nix) and could also read
# /vault directly; the mount keeps the path the agent's existing state
# references. The VM-era notes below still describe the mount's rationale.
#
# What works and what does not (measured 2026-09-06):
#   - a symlink into /vault dangles in the guest: bind mount needed.
#   - virtiofsd resolves guest reads with the host's NFS credentials. With
#     no_root_squash (vault-nfs-server.nix) guest root is real root on this
#     dir, and the bind mount below is the only vault path the guest sees.
#     The tree is 2775/664 so group vault (dave/grmpf) can write alongside
#     momentum.
#   - nofail keeps boot independent of bam; the automount materializes on
#     first access as elsewhere.
#   - read-only: the microVM must never modify the datasets; they are written
#     by host-side jobs through the /vault path. systemd implements
#     bind+ro as bind followed by a ro remount.
{
  fileSystems."/home/momentum/hermes/state" = {
    device = "/vault/parquet/momentum";
    fsType = "none";
    options = [
      "bind"
      "ro"
      "nofail"
      # triggers the /vault automount (vault-nfs-client.nix) first
      "x-systemd.requires-mounts-for=/vault"
    ];
  };
}
