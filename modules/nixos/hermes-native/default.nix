# Native Hermes agents (NousResearch hermes-agent): per user, the gateway
# and web dashboard run on the host as that user's own account, with no
# microVM (`services.hermes-native`). Owned here so the runtime can change
# without a spaces bump; vendored from the native path of spaces 6d744780
# modules/nixos/hermes/. spaces' `services.hermes-microvm` keeps the
# microVM agents and the desktop client.
#
# Per-agent separation, every piece of which must survive a change here:
#   - state in /var/lib/hermes-microvm/<user>/state-vault/state, 0700 the
#     owner, inside a root 0711 vault (sockets.nix),
#   - secrets as systemd credentials of hermes-agent-<user>, rewritten
#     into the owner's 0600 .env; never in the store (native.nix),
#   - a per-agent managed config dir (HERMES_MANAGED_DIR) pinning exactly
#     the Nix keys (native.nix),
#   - root-held public ports bridged per connection to the owner's
#     backend by an owner-uid-checking forward (sockets.nix),
#   - owner-only iptables gates on every public and backend port
#     (firewall.nix).
#
# INVARIANT: one state vault has one runner. A user runs either here or
# in a spaces microVM, never both (asserted per host; units guard at
# start).
#
# `inputs` are this flake's (specialArgs): hermes-agent for the package,
# spaces for agent-skills and simplex-chat.
{
  imports = [
    ./options.nix
    ./native.nix
    ./sockets.nix
    ./firewall.nix
    ./cli.nix
    ../hermes-searxng.nix
  ];
}
