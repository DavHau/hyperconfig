# som agents in dave's Hermes desktop launchers: account -> { label; isolatedDesktop? }.
# Used by ./hermes-desktop.nix, ./hermes-desktop-spaces.nix and
# machines/som/hermes-agents.nix (assertion: each agent with a TUI entry
# needs ssh keys, the TUI entries log in as the agent).
#
#   label            shown in the app and the launcher entries.
#   isolatedDesktop  set: the agent is left out of the shared "Hermes
#                    Desktop" app and gets no TUI entry; instead it has its
#                    own "Hermes (<label>)" app, run in a container of its
#                    own (./hermes-desktop-spaces.nix), like infra-space's
#                    (./infra-space/desktop-app.nix). That app exists only
#                    on the desktops importing ./hermes-desktop-spaces.nix
#                    (amy); elsewhere the agent has no launcher at all.
#                    Its fields:
#                      index  the container's veth subnet, 10.235.1.<4i>/30
#                             and fd23:5ace:1:<i>::/64, 0..3 (sites.nix
#                             claims 10.235.1.0/28); never reused.
#                      uid    the container user's uid (owns its home on
#                             the host), distinct; id ladder in
#                             ./vault-ids.nix.
#                      name   optional, the container's name, default
#                             hermes-<agent>; at most 12 characters.
{
  dave-hermes.label = "dave-hermes";
  joe.label = "joe";
  thaigersprint.label = "thaigersprint";
  # The Voice PE's untrusted agent (../../machines/som/hermes-agents.nix).
  voice = {
    label = "voice";
    isolatedDesktop = {
      index = 0;
      uid = 1214;
    };
  };
}
