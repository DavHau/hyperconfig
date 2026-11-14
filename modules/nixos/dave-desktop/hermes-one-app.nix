/*
  Hermes One (../../../pkgs/hermes-one) as a launcher script: a function
  from a Wayland app id and the managed dashboards to a script that merges
  them into the app's connection registry (./hermes-one-connections.py)
  and runs the app. Used by ./hermes-one.nix (Dave's session) and
  ./isolated-apps.nix (inside a container, through ../space-gui).

    import ./hermes-one-app.nix { inherit lib pkgs; package = <hermes-one>; }
      { appId = "hermes-one"; primary = "x"; remotes.x = { label = "x"; url = "https://x.example.org"; };
        container = false; }

  State, all under the running user's home and nowhere else:
    - ~/.local/share/hermes-one: HERMES_HOME, i.e. desktop.json (the
      connection registry, no credentials) and whatever the app keeps per
      profile. Never ~/.hermes: the app must not touch a Hermes Agent home.
    - ~/.config/hermes-one: Electron userData, i.e. the OAuth cookie
      partition holding each dashboard's session.
  Neither is shared with the official app (~/.config/Hermes).

  The Wayland app id comes from package.json's desktopName (Electron uses
  it), so the app directory is the package's with that one field set.
  `container = true`: software rendering (the containers have no /dev/dri).
*/
{
  lib,
  pkgs,
  package,
}:
{
  appId,
  primary,
  remotes,
  container ? false,
}:
let
  share = "${package}/share/hermes-one";
  appDir = pkgs.runCommand "${appId}-app" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir $out
    for f in out resources node_modules LICENSE; do ln -s ${share}/$f $out/$f; done
    jq '.desktopName = "${appId}.desktop"' ${share}/package.json > $out/package.json
  '';
  spec = pkgs.writeText "${appId}-connections.json" (builtins.toJSON { inherit primary remotes; });
in
pkgs.writeShellScript appId ''
  set -e
  export HERMES_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}/hermes-one"
  export HERMES_DESKTOP_USER_DATA_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/hermes-one"
  mkdir -p -m 700 "$HERMES_HOME" "$HERMES_DESKTOP_USER_DATA_DIR"
  ${pkgs.python3}/bin/python3 ${./hermes-one-connections.py} ${spec}
  export NODE_ENV=production ELECTRON_IS_DEV=0
  unset ELECTRON_RENDERER_URL MAIN_VITE_HERMES_API_URL HERMES_API_KEY MAIN_VITE_HERMES_API_KEY ENABLE_CDP
  # The Hermes One account (device login, cloud agent sync) defaults to
  # http://localhost:3002, on som any tenant's port: point it at a name
  # that never resolves (RFC 6761), so its button fails instead.
  export HERMES_API_URL=https://hermes-one-account.invalid
  ${lib.optionalString container "export HERMES_DISABLE_GPU=1"}
  exec ${lib.getExe package.electron} --ozone-platform=wayland \
    --enable-features=WaylandWindowDecorations ${lib.optionalString container "--disable-gpu "}${appDir} "$@"
''
