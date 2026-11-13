# som agents in dave's Hermes desktop app and TUI launchers: account -> label.
# Used by ./hermes-desktop.nix and machines/som/hermes-agents.nix (assertion:
# each needs ssh keys, the TUI entries log in as the agent).
{
  dave-hermes = "dave-hermes";
  joe = "joe";
  thaigersprint = "thaigersprint";
  # The Voice PE's untrusted agent (../../machines/som/hermes-agents.nix).
  voice = "voice";
}
