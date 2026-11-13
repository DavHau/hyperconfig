# Hermes launchers on the dave desktops for som's agents
# (machines/som/hermes-agents.nix), through hyperhermes' desktop module:
# `hermes-desktop` (the Electron app, also what the niri keybind and the
# bar button spawn via spaces-hermes), plus a "Hermes Desktop" entry and
# one "Hermes TUI (<agent>)" entry per agent. The module's header has the
# connection mechanics; this file has som's side of them.
#
# The app opens each agent's always-on dashboard on som,
# https://<agent>.davhau.fyi (../../machines/som/hermes-dashboards.nix),
# and signs in through pocket-id: dave signs in once per agent inside the
# app. Chats run in som's dashboard units, so quitting the app leaves them
# running.
#
# The TUI entries dial <agent>@hermes.davhau.com (som's public name) with
# the user's normal identities (the agent accounts take the admin keys),
# the host verified as `som.d`: som presents its clan sshd CA certificate
# (principal som.d) on every address, and the sshd client role trusts that
# CA for `*.d` in ssh_known_hosts.
{ config, ... }:
{
  # hyperhermes' desktop module itself is imported next to this file in
  # ./dave.nix.
  services.hyperhermes.desktop = {
    enable = true;
    host = "hermes.davhau.com";
    domain = (import ../../machines/som/hermes-dashboards.nix).domain;
    hostLabel = "som";
    hostKeyAlias = "som.d";
    # Agent account on som -> label; the first window opens on `primary`.
    agents = {
      dave-hermes = "dave-hermes";
      joe = "joe";
      thaigersprint = "thaigersprint";
      # The Voice PE's untrusted agent (../../machines/som/hermes-agents.nix).
      voice = "voice";
    };
    primary = "dave-hermes";
    # spaces-hermes runs `hermes-desktop` and turns a failure into a
    # desktop notification, as the keybind and the bar button do.
    desktopEntryExec = "${config.services.spaces.commands.hermes}/bin/spaces-hermes";
  };
}
