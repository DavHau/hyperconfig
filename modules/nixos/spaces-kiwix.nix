# Offline Wikipedia for the spaces agents.
#
# The `offline-wiki` integration serves every `*.zim` archive in a directory.
# Those archives are host state the operator supplies (50-100 GB, from
# <https://download.kiwix.org/zim/wikipedia/>); spaces never fetches them, and
# an empty directory makes the tools answer "no archives" rather than fail the
# build. The path lowers to OFFLINE_WIKI_ZIM_DIR and a Landlock grant, so it
# must be absolute (asserted in spaces-integrations/default.nix).
#
# Side effect worth knowing: `services.spaces-integrations.enable` is the
# default source for hermes' per-user `spacesGateway.enable`
# (hermes/options.nix), so turning integrations on here is what bridges the
# gateway socket into the hermes VM.
{ ... }:
{
  services.spaces-integrations = {
    enable = true;
    offline-wiki.zimDir = "/var/lib/kiwix";
  };

  # Keyed by a normal user in users.users - an unknown name trips the
  # spaces.users assertion even when integrations are disabled.
  spaces.users.grmpf.integrations.offline-wiki.enable = true;
}
