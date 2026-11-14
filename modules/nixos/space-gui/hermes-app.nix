/*
  The hermes desktop app as a space-gui command (./default.nix): a
  function from a Wayland app id and the managed connections to a script
  that runs in the space's container, as its user. Used by
  ../dave-desktop/isolated-apps.nix.

    import ./hermes-app.nix { inherit lib pkgs; desktop = config.services.hyperhermes.desktop; }
      { appId = "hermes-x"; primary = "x"; remotes.x = { label = "x"; url = "https://x.example.org"; }; }

  The app and connection mechanics are Dave's own hermes-desktop's
  (hyperhermes' desktop module, ../dave-desktop/shared-app.nix): `remote`
  connections with authMode oauth, merged into the app's files by that
  module's connections.py on every launch. All its state (config, cookies,
  tokens) lives in the container user's ~/.config/Hermes, never in the
  host user's home.

  The dashboards offer the native PKCE sign-in: the app opens the
  authorize URL through xdg-open (space-gui's broker: the host user's
  browser, only the container's `openOrigins`) and waits on the
  container's loopback, which the broker forwards from the host for the
  redirect.

  The Wayland app id is set through package.json's desktopName, which
  Electron uses for it; the window title stays the app's ("Hermes").
  Software rendering: the containers have no /dev/dri.
*/
{
  lib,
  pkgs,
  desktop,
}:
{
  appId,
  primary,
  remotes,
}:
let
  # The app directory with its own desktopName; dist and the stamp are the
  # package's (dist's main script resolves its resources by store path).
  appDir = pkgs.runCommand "${appId}-app" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir $out
    share=${desktop.package}/share/hermes-desktop
    ln -s $share/dist $share/install-stamp.json $out/
    jq '.desktopName = "${appId}.desktop"' $share/package.json > $out/package.json
  '';

  spec = pkgs.writeText "${appId}-connections.json" (builtins.toJSON { inherit primary remotes; });
in
# Runs in the container. The wrapper's env and flags are the package's
# (bin/hermes-desktop), only the app directory differs.
pkgs.writeShellScript appId ''
  set -e
  ${pkgs.python3}/bin/python3 ${../../../hyperhermes/modules/desktop/connections.py} ${spec}
  wrapper=${desktop.package}/bin/hermes-desktop
  eval "$(${pkgs.gnugrep}/bin/grep '^export ' "$wrapper")"
  export HERMES_DESKTOP_DISABLE_GPU=1
  exec ${lib.getExe pkgs.electron} --ozone-platform=wayland \
    --enable-features=WaylandWindowDecorations ${appDir} "$@"
''
