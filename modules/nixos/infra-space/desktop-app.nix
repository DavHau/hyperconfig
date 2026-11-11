/*
  "Hermes (infra-space)": the hermes desktop app run in this host's
  infra-space container (as `infra`, through ../space-gui) on Dave's
  Wayland session, connected to the infra-space agent's dashboard on som,
  https://infra-space.davhau.fyi (./dashboard.nix), with its OIDC sign-in
  through pocket-id.

  The same app and connection mechanics as Dave's own hermes-desktop
  (hyperhermes' desktop module, ../hermes-desktop.nix): one managed
  `remote` connection with authMode oauth, merged into the app's files by
  that module's connections.py on every launch. All its state (config,
  cookies, tokens) lives in the container's /home/infra (.config/Hermes),
  never in grmpf's home, so the two apps share nothing.

  The dashboard offers the native PKCE sign-in: the app opens the
  authorize URL through xdg-open (space-gui's broker: Dave's browser, only
  this dashboard's origin) and waits on the container's loopback, which
  the broker forwards from this host for the redirect.

  Wayland app id `hermes-infra-space` (Dave's own app has `hermes`), set
  through package.json's desktopName, which Electron uses for it; the
  window title stays the app's ("Hermes"). Software rendering: the
  container has no /dev/dri.
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
  appId = "hermes-infra-space";

  # The app directory with its own desktopName; dist and the stamp are the
  # package's (dist's main script resolves its resources by store path).
  appDir = pkgs.runCommand "hermes-infra-space-app" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir $out
    share=${desktop.package}/share/hermes-desktop
    ln -s $share/dist $share/install-stamp.json $out/
    jq '.desktopName = "${appId}.desktop"' $share/package.json > $out/package.json
  '';

  spec = pkgs.writeText "hermes-infra-space-connections.json" (
    builtins.toJSON {
      primary = account.name;
      remotes.${account.name} = {
        label = "infra-space";
        inherit url;
      };
    }
  );

  # Runs in the container as infra. The wrapper's env and flags are the
  # package's (bin/hermes-desktop), only the app directory differs.
  app = pkgs.writeShellScript "hermes-infra-space" ''
    set -e
    ${pkgs.python3}/bin/python3 ${../../../hyperhermes/modules/desktop/connections.py} ${spec}
    wrapper=${desktop.package}/bin/hermes-desktop
    eval "$(${pkgs.gnugrep}/bin/grep '^export ' "$wrapper")"
    export HERMES_DESKTOP_DISABLE_GPU=1
    exec ${lib.getExe pkgs.electron} --ozone-platform=wayland \
      --enable-features=WaylandWindowDecorations ${appDir} "$@"
  '';
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
