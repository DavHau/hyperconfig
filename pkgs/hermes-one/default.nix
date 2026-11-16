# Hermes One (https://github.com/fathah/hermes-desktop, MIT): a third-party
# Electron desktop app for Hermes Agent, built from source against
# nixpkgs' electron, as a remote-only client for hermes dashboards. Used by
# ../../modules/nixos/dave-desktop/hermes-one.nix.
#
# ./remote-models-all-configured.patch: a remote dashboard's model list
#   shows every explicitly configured provider (OpenRouter included), not
#   only the current one and user-defined endpoints.
# ./nix-remote-only.patch (tested by the build's vitest run):
#   - sign-in: a dashboard that advertises `native_pkce` (hermes'
#     /auth/native/*) is signed in through the user's own browser (RFC
#     8252, loopback redirect), its tokens stored as the dashboard's own
#     session cookies in the app's OAuth partition. Upstream only has an
#     embedded window, where a pocket-id passkey cannot be used;
#   - electron-updater never starts (Nix owns updates);
#   - the local Hermes Agent installer (upstream's install.sh into
#     ~/.hermes) and the Hermes Office setup (git clone + npm install)
#     refuse to run;
#   - no project `.env` is read from the working directory.
# ./links-external.patch: every link opens in the system browser, only on
#   the user's click; the in-app "Web Preview" pane (a <webview>) and its
#   automatic opening on web tool events are gone.
# What stays off without a patch: analytics (needs build-time
# VITE_ANALYTICS_* secrets, unset here), the Hermes One account (device
# login, only on a click; the wrappers point HERMES_API_URL at
# hermes-one-account.invalid instead of the built-in localhost:3002) and its
# cloud agent sync / inference key provisioning (only after that login).
# Chromium itself fetches its spell-check dictionary from Google
# (redirector.gvt1.com) on first start. The Discover tab still fetches the public registry
# (GitHub, registry.hermesone.org icons) when opened.
#
# Runtime: `electron <app dir>`; app.isPackaged is false for that, so the
# wrapper sets NODE_ENV=production and ELECTRON_IS_DEV=0 (the toolkit's
# is.dev would otherwise load ELECTRON_RENDERER_URL). better-sqlite3 is
# rebuilt against electron's headers (its prebuilds are for Node).
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  electron_44,
  nodejs_22,
  node-gyp,
  makeWrapper,
  python3,
}:
let
  electron = electron_44;
in
buildNpmPackage rec {
  pname = "hermes-one";
  version = "0.7.8";

  src = fetchFromGitHub {
    owner = "fathah";
    repo = "hermes-desktop";
    rev = "v${version}";
    hash = "sha256-tjzxSWFRNEsJ0EJS0zXFIdR4Z4q6HlaZRl9l10l2FBo=";
  };

  patches = [
    ./nix-remote-only.patch
    ./remote-models-all-configured.patch
    ./links-external.patch
  ];

  # ./remote-models-all-configured.patch's behaviour (and upstream's cases
  # for the same file).
  postCheck = ''
    # These import the `electron` npm stub, which has no binary here.
    ELECTRON_OVERRIDE_DIST_PATH=${electron}/bin \
    node node_modules/vitest/vitest.mjs run \
      tests/remote-models.test.ts src/main/remote-models.ipc.test.ts
  '';

  npmDepsHash = "sha256-yjLIByolfYcOjgCZ+gZuOSf9sx8AwwQZiW5hEr64fRY=";
  nodejs = nodejs_22;

  # postinstall downloads electron and runs electron-builder; neither here.
  npmFlags = [ "--ignore-scripts" ];
  makeCacheWritable = true;

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    npm_config_build_from_source = "true";
  };

  nativeBuildInputs = [
    makeWrapper
    python3
  ];

  buildPhase = ''
    runHook preBuild

    # better-sqlite3 against this electron's ABI (its prebuilds are Node's).
    rm -rf node_modules/better-sqlite3/prebuilds
    (cd node_modules/better-sqlite3 && \
      ${lib.getExe node-gyp} rebuild --release \
        --runtime=electron --target=${electron.version} \
        --nodedir=${electron.headers} --disturl="" --offline)

    npm run typecheck
    node node_modules/electron-vite/bin/electron-vite.js build

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # The patch's behaviour, plus upstream's own OAuth boundary tests.
    node node_modules/vitest/vitest.mjs run \
      tests/remote-oauth-native.test.ts tests/remote-oauth.test.ts \
      src/renderer/src/components/AgentMarkdown.links-external.test.tsx
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    app=$out/share/hermes-one
    mkdir -p $app $out/bin $out/share/icons/hicolor/512x512/apps
    cp -r out resources package.json LICENSE $app/
    npm prune --omit=dev --no-audit --no-fund --ignore-scripts
    cp -r node_modules $app/
    rm -rf $app/node_modules/electron $app/node_modules/.bin
    # Only the addon itself; the build tree and sqlite's objects are dead weight.
    bsq=$app/node_modules/better-sqlite3
    mv $bsq/build/Release/better_sqlite3.node $TMPDIR/
    rm -rf $bsq/build $bsq/deps $bsq/src
    install -Dm755 $TMPDIR/better_sqlite3.node $bsq/build/Release/better_sqlite3.node
    install -Dm644 resources/icon.png $out/share/icons/hicolor/512x512/apps/hermes-one.png

    makeWrapper ${lib.getExe electron} $out/bin/hermes-one \
      --add-flags $app \
      --add-flags "--enable-features=WaylandWindowDecorations" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform=wayland}}" \
      --set NODE_ENV production \
      --set ELECTRON_IS_DEV 0 \
      --unset ELECTRON_RENDERER_URL \
      --set HERMES_API_URL https://hermes-one-account.invalid \
      --run 'export HERMES_HOME="''${HERMES_HOME:-$HOME/.local/share/hermes-one}"' \
      --unset MAIN_VITE_HERMES_API_URL

    runHook postInstall
  '';

  passthru = { inherit electron; };

  meta = {
    description = "Hermes One, a third-party desktop app for Hermes Agent (remote-only build)";
    homepage = "https://github.com/fathah/hermes-desktop";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "hermes-one";
  };
}
