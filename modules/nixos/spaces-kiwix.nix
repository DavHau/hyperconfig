# Offline Wikipedia for the spaces agents.
#
# The `offline-wiki` integration serves every `*.zim` archive in one fixed
# per-user directory, ~/.local/share/spaces/offline-wiki (spaces
# spaces-integrations/defaults.nix creates it; no option since spaces
# cf86beae). Those archives are host state the operator supplies (50-100 GB,
# from <https://download.kiwix.org/zim/wikipedia/>); spaces never fetches
# them, and an empty directory makes the tools answer "no archives" rather
# than fail the build.
#
# Side effect worth knowing: `services.spaces-integrations.enable` is the
# default source for hermes' per-user `spacesGateway.enable` (spaces
# hermes/options.nix for a VM agent, ./hermes-native/options.nix for a
# native one), so turning integrations on here is what hands the gateway
# socket to the agent.
{ ... }:
{
  services.spaces-integrations.enable = true;

  # Keyed by a normal user in users.users - an unknown name trips the
  # spaces.users assertion even when integrations are disabled.
  spaces.users.grmpf.integrations.offline-wiki.enable = true;
}
