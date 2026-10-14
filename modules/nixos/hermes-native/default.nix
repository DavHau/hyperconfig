# Hermes agents (NousResearch hermes-agent) running natively on the host
# (`services.hermes-native`): per user, the gateway and the web dashboard
# run as that user's own account.
#
# Per-agent separation, every piece of which must survive a change here:
#   - state in /var/lib/hermes/<user>/state, 0700 the owner, inside a root
#     0711 directory (agents.nix),
#   - secrets as systemd credentials of hermes-agent-<user>, rewritten
#     into the owner's 0600 .env; never in the store (agent-config.nix),
#   - a per-agent managed config dir (HERMES_MANAGED_DIR) pinning exactly
#     the Nix keys (agents.nix),
#   - root-held dashboard and browser-server ports, bridged per
#     connection to the owner's backends by an owner-uid-checking forward
#     (forwards.nix),
#   - owner-only iptables gates on those ports and their backends
#     (firewall.nix),
#   - a per-agent Camofox browser server as the owner, its access key and
#     profile store in the owner's 0700 state dir (camofox.nix).
#
# `inputs` are this flake's (specialArgs): hermes-agent for the package,
# spaces for the agent skills.
{
  imports = [
    ./options.nix
    ./agents.nix
    ./forwards.nix
    ./firewall.nix
    ./searxng.nix
    ./web-extract.nix
    ./camofox.nix
  ];
}
