# The shared "Hermes Desktop" app on Dave's desktops (./default.nix) for
# som's agents (machines/som/hermes-agents.nix), through hyperhermes'
# desktop module: `hermes-desktop` (the Electron app, also what the niri
# keybind and the bar button spawn via spaces-hermes) and its "Hermes
# Desktop" entry. The module's header has the connection mechanics; this
# file has som's side of them. Apps marked `isolated` in ./apps.nix are not
# in it: they get an app of their own in a container (./isolated-apps.nix).
#
# The app opens each agent's always-on dashboard on som,
# https://<agent>.davhau.fyi (../../../machines/som/hermes-dashboards.nix),
# and signs in through pocket-id: dave signs in once per agent inside the
# app. Chats run in som's dashboard units, so quitting the app leaves them
# running.
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.hyperhermes.nixosModules.desktop ];

  services.hyperhermes.desktop = {
    enable = true;
    domain = (import ../../../machines/som/hermes-dashboards.nix).domain;
    hostLabel = "som";
    # Agent account on som -> label.
    agents = lib.mapAttrs (_: a: a.label) (lib.filterAttrs (_: a: !(a ? isolated)) (import ./apps.nix));
    # The first window opens on `primary`.
    primary = "dave-hermes";
    # spaces-hermes runs `hermes-desktop` and turns a failure into a
    # desktop notification, as the keybind and the bar button do.
    desktopEntryExec = "${config.services.spaces.commands.hermes}/bin/spaces-hermes";
  };
}
