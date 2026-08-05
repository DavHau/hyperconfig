# Offline Wikipedia for the spaces agents.
#
# The `kiwix` integration serves one ZIM archive. That archive is host state
# the operator supplies (50-100 GB, from <https://download.kiwix.org/zim/
# wikipedia/>); spaces never fetches it, and a missing file makes the tools
# answer "unreadable_archive" rather than fail the build. The path lowers to
# both KIWIX_ARCHIVE and a Landlock grant on its parent directory, so it must
# be absolute (asserted in spaces-integrations/default.nix).
#
# Side effect worth knowing: `services.spaces-integrations.enable` is the
# default source for hermes' per-user `spacesGateway.enable`
# (hermes/options.nix), so turning integrations on here is what bridges the
# gateway socket into the hermes VM.
{ ... }:
{
  services.spaces-integrations = {
    enable = true;
    kiwix.archive = "/var/lib/kiwix/wikipedia_en_all_nopic_2026-06.zim";
  };

  # Keyed by a normal user in users.users - an unknown name trips the
  # spaces.users assertion even when integrations are disabled.
  spaces.users.grmpf.integrations.kiwix.enable = true;
}
