# Hermes launchers on the dave desktops for som's agents
# (machines/som/hermes-agents.nix), through hyperhermes' desktop module:
# `hermes-desktop` (the Electron app, also what the niri keybind and the
# bar button spawn via spaces-hermes), plus a "Hermes Desktop" entry and
# one "Hermes TUI (<agent>)" entry per agent. The module's header has the
# connection mechanics; this file has som's side of them.
#
# The app dials the agents as <agent>@hermes.davhau.com (som's public
# name) with the shared clan var hermes-desktop-ssh, copied for dave plus
# grmpf where that account exists (amy). som authorizes its public half
# on dave-hermes and joe with `restrict` + loopback port-forwarding only.
# BatchMode cannot answer a TOFU prompt, so the host is verified as
# `som.d`: som presents its clan sshd CA certificate (principal som.d) on
# every address, and the sshd client role trusts that CA for `*.d` in
# ssh_known_hosts. The TUI entries use the user's normal identities (the
# agent accounts take the admin keys).
{
  config,
  inputs,
  lib,
  ...
}:
{
  # hyperhermes' desktop module itself is imported next to this file in
  # ./dave.nix; its clan module fills sshKeyFile.
  imports = [ inputs.hyperhermes.nixosModules.clan ];

  services.hyperhermes.desktop = {
    enable = true;
    host = "hermes.davhau.com";
    hostLabel = "som";
    hostKeyAlias = "som.d";
    # Agent account on som -> label; the first window opens on `primary`.
    agents = {
      dave-hermes = "dave-hermes";
      joe = "joe";
    };
    primary = "dave-hermes";
    users = [ "dave" ] ++ lib.optional (config.users.users ? grmpf) "grmpf";
    # spaces-hermes runs `hermes-desktop` and turns a failure into a
    # desktop notification, as the keybind and the bar button do.
    desktopEntryExec = "${config.services.spaces.commands.hermes}/bin/spaces-hermes";
  };
}
