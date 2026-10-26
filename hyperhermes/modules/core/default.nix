# Hermes agents (NousResearch hermes-agent) running natively on the host
# (`services.hyperhermes.agents`): per agent, the gateway and the web
# dashboard run as that agent's own login account. Core is on as soon as
# one agent is declared.
#
# Per-agent separation, every piece of which must survive a change here:
#   - state in /var/lib/hermes/<agent>/state, 0700 the owner, inside a root
#     0711 directory (agents.nix),
#   - secrets as systemd credentials of hermes-agent-<agent>, rewritten
#     into the owner's .env; never in the store (agent-config.nix),
#   - a per-agent managed config dir (HERMES_MANAGED_DIR) pinning exactly
#     the Nix keys (agents.nix),
#   - root-held dashboard ports (and those features add), bridged per
#     connection to the owner's backends by an owner-uid-checking forward
#     (forwards.nix),
#   - owner-only iptables gates on those ports and their backends
#     (firewall.nix).
#
# `hermes-agent` is this flake's input: the package source and its
# config merge script.
{ hermes-agent }:
let
  # lib.modules.importApply, without needing lib to build `imports`.
  importApply = file: arg: {
    _file = file;
    imports = [ (import file arg) ];
  };
in
{
  imports = [
    (importApply ./options.nix { inherit hermes-agent; })
    ./accounts.nix
    (importApply ./agents.nix { inherit hermes-agent; })
    ./forwards.nix
    ./firewall.nix
  ];
}
