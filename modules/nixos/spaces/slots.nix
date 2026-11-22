# Container slots (hyperhermes' container-slots, deployed from other
# repos) that Dave reaches from his desktops like a space: plain data, read
# by ./slot-forwards.nix (the slot's machine) and ./public.nix (Dave's
# desktops, through ./client.nix: the ssh alias `<slot>-<machine>`, the
# pinned host key, the herdr machine).
#
#   machine   where the slot runs (services.container-slots.slots.<name>)
#   sshPort   the port on that machine's yggdrasil address forwarded to the
#             slot's sshd: the spaces' ladder (./registry.nix; 2222 unlock,
#             2223 infra-space, 2224 geninf-space, 2225 retired, 2226
#             agave-host), next free 2228
#   user      the login user in the slot
#   hostKey   the slot's ed25519 host key (container-slots writes it once,
#             the guest keeps it; `ssh-keyscan` of its address returns it).
#             If it changes, every login fails closed until this is updated.
#   session   herdr session of the herdr machine (default "default")
{
  # nmm's `agents` machine (the asof project's swarm), som's slot id 3.
  asof-agents = {
    machine = "som";
    sshPort = 2227;
    user = "agent";
    hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAhfUS9DBVDIF2DWfJEGYdcLOGqhcYdB9wlrxZCfRF0t";
    session = "swarm";
  };
}
