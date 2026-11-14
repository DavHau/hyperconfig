/*
  "Hermes (infra-space)": the hermes desktop app run in this host's
  infra-space container (as `infra`, through ../space-gui) on Dave's
  Wayland session, connected to the infra-space agent's dashboard on som,
  https://infra-space.davhau.fyi (./dashboard.nix), with its OIDC sign-in
  through pocket-id.

  The app, its connection and sign-in mechanics: ../space-gui/hermes-app.nix
  (shared with the per-agent desktop spaces, ../hermes-desktop-spaces.nix).
  All its state lives in the container's /home/infra (.config/Hermes),
  never in grmpf's home, so the two apps share nothing.

  Wayland app id `hermes-infra-space` (Dave's own app has `hermes`).
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  desktop = config.services.hyperhermes.desktop;
  account = import ./dashboard-account.nix;
  url = "https://${account.name}.${desktop.domain}";

  app = import ../space-gui/hermes-app.nix { inherit lib pkgs desktop; } {
    appId = "hermes-infra-space";
    primary = account.name;
    remotes.${account.name} = {
      label = "infra-space";
      inherit url;
    };
  };
in
{
  imports = [ ../space-gui ];

  hyper.spaceGui = {
    enable = true;
    containers.infra-space = {
      user = "infra";
      uid = 1203; # the guest user infra (./default.nix)
      home = "/home/infra";
      openOrigins = [ url ];
    };
    apps.hermes-infra-space = {
      container = "infra-space";
      command = [ "${app}" ];
      desktopName = "Hermes (infra-space)";
      icon = "${desktop.package}/share/hermes-desktop/dist/hermes.png";
    };
  };
}
