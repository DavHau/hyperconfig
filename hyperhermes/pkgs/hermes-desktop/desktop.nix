# Hermes Desktop (Electron) app build + wrapper.
#
# Vendored from hermes-agent nix/desktop.nix, last diffed at v0.22.5;
# diff against upstream when bumping the input. Upstream now takes the
# node-pty headers from `electron.headers` itself, which is what lets this
# copy build against the caller's electron. What differs:
#   - the desktop-entry script comes from the injected hermesSrc (upstream's
#     ../ sibling paths resolve to nothing here);
#   - the `hermes://session/<id>` deep link
#     (./patches/desktop-session-deeplink.patch);
#   - the wrapper symlinks the renderer instead of copying it (below);
#   - no extraEnv/extraRun: nothing here sets them.
#
# `hermesAgent` is the fully-built `.#default` package — it ships the
# `hermes` binary with the venv, runtime PATH, bundled skills/plugins, etc.
# already wired up.  We point the desktop at it via the existing
# `HERMES_DESKTOP_HERMES` override env var, so the desktop's resolver
# uses our fully wrapped binary before the mutable managed install.
# No reimplementation of the agent resolution in this wrapper.
{
  lib,
  stdenv,
  makeWrapper,
  hermesNpmLib,
  electron,
  hermesAgent,
  installStampFile,
  generatedIcons,
  hermesSrc,
  python3,
  ...
}:
let
  wrapperArgs = [
    "--add-flags"
    "--enable-features=WaylandWindowDecorations"
    "--add-flags"
    "${placeholder "out"}/share/hermes-desktop"
    "--set"
    "HERMES_DESKTOP_HERMES"
    (lib.getExe hermesAgent)
    "--set"
    "ELECTRON_IS_DEV"
    "0"
  ];

  # node-pty ships no Electron-tagged prebuild we can trust to match this
  # exact nixpkgs electron version, so it's always compiled from source
  # against Electron's own headers (not whatever Node ran `npm`).
  targetPlatform =
    if stdenv.hostPlatform.isDarwin then
      "darwin"
    else if stdenv.hostPlatform.isLinux then
      "linux"
    else
      throw "hermes-desktop: unsupported host platform for node-pty staging";

  targetArch =
    if stdenv.hostPlatform.isAarch64 then
      "arm64"
    else if stdenv.hostPlatform.isx86_64 then
      "x64"
    else
      throw "hermes-desktop: unsupported host arch for node-pty staging";

  # Build the renderer (dist/ + electron/ + package.json).
  renderer = hermesNpmLib.buildNpmPackage {
    dirs = [
      "apps/desktop"
      "apps/shared"
      "scripts/build/desktop.mjs"
      "scripts/build/freshness.mjs"
      "scripts/build/frontend-common.mjs"
      # product-identity.cjs resolves the channel request through the
      # packaging helper (and its content-types table).
      "scripts/msix-shared.mjs"
      "scripts/release-content-types.json"
    ];
    pname = "hermes-desktop-renderer";

    doCheck = true;

    # `hermes-desktop hermes://session/<id>` opens that chat, and a second
    # launch switches the running window to it. The patch header names what
    # upstream lacks; building packages.hermes-desktop proves it applies to
    # the pinned input.
    patches = [ ./patches/desktop-session-deeplink.patch ];

    buildPhase = ''
      runHook preBuild

      patchShebangs .

      # Compile node-pty against the exact Electron runtime this derivation
      # ships. `electron.headers` cannot drift from `electron.version`; the
      # sandbox has no network for node-gyp's --disturl path.
      ${lib.getExe hermesNpmLib.node-gyp} rebuild \
        --directory=node_modules/node-pty \
        --build-from-source \
        --runtime=electron \
        --target=${electron.version} \
        --arch=${targetArch} \
        --nodedir=${electron.headers} \
        --disturl="" \
        --offline

      node apps/desktop/scripts/stage-native-deps.mjs \
        --source "$PWD" --out "$TMPDIR/desktop-native-deps" \
        --platform ${targetPlatform} --arch ${targetArch}
      node scripts/build/desktop.mjs \
        --source "$PWD" --out "$PWD/apps/desktop/dist" \
        --icons ${generatedIcons} --stamp ${installStampFile} \
        --native-deps "$TMPDIR/desktop-native-deps" \
        --platform ${targetPlatform} --typecheck

      runHook postBuild
    '';

    checkPhase = ''
      runHook preCheck

      pushd apps/desktop

        node scripts/assert-dist-built.mjs

        # validate staged node-pty native binary is present.
        STAGED_PTY_NODE="./dist/node_modules/node-pty/build/Release/pty.node"

        if [ ! -f "$STAGED_PTY_NODE" ]; then
          echo "FATAL: Missing staged node-pty native binary at $STAGED_PTY_NODE"
          echo "node-pty must be compiled natively"
          exit 1
        fi

      popd

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      # The shared product contains renderer, main/preload, and native deps.
      cp -rn apps/desktop/dist $out/

      cp ${installStampFile} $out/install-stamp.json

      cp -n apps/desktop/package.json $out/
      runHook postInstall
    '';
  };
in

# Electron wrapper: nixpkgs' electron binary pointed at the renderer dir.
stdenv.mkDerivation {
  pname = "hermes-desktop";
  inherit (renderer) version;

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [
    makeWrapper
    python3
  ];

  installPhase = ''
    runHook preInstall

    # Symlinks, not a copy. A copy leaves ${renderer} out of the runtime
    # closure, so the installer ISO never staged it and every install
    # that touched this wrapper rebuilt the whole Electron renderer: 771
    # npm fetches, node-gyp, a second nodejs (2026-09). Referenced, the
    # renderer is staged and a wrapper change costs one second. Only
    # electron-main.mjs is a real file: it gets $out patched in below.
    mkdir -p $out/share/hermes-desktop/dist $out/bin
    for f in ${renderer}/*; do
      [ "$(basename "$f")" = dist ] || ln -s "$f" $out/share/hermes-desktop/
    done
    for f in ${renderer}/dist/*; do
      [ "$(basename "$f")" = electron-main.mjs ] || ln -s "$f" $out/share/hermes-desktop/dist/
    done
    cp ${renderer}/dist/electron-main.mjs $out/share/hermes-desktop/dist/
    chmod u+w $out/share/hermes-desktop/dist/electron-main.mjs

    # Standard nixpkgs pattern for electron-builder apps: patch process.resourcesPath
    # to point to the app's directory. In Nix, unpackaged electron defaults this
    # to the electron distribution's resources path, breaking extraResources lookups.
    substituteInPlace $out/share/hermes-desktop/dist/electron-main.mjs \
      --replace-fail "process.resourcesPath" "'$out/share/hermes-desktop'"

    # Wrap the nixpkgs electron binary to launch our app.
    makeWrapper ${lib.getExe electron} $out/bin/hermes-desktop \
      ${lib.escapeShellArgs wrapperArgs}

    # XDG launcher entry
    mkdir -p $out/share/applications $out/share/icons/hicolor/1024x1024/apps
    install -m 0644 ${generatedIcons}/apps/desktop/assets/icon.png \
      $out/share/icons/hicolor/1024x1024/apps/hermes.png
    export PYTHONPATH=$(mktemp -d)
    cp ${hermesSrc}/hermes_cli/linux_desktop_entry.py "$PYTHONPATH/linux_desktop_entry.py"
    export DESKTOP_EXEC="$out/bin/hermes-desktop"
    export DESKTOP_ICON="$out/share/icons/hicolor/1024x1024/apps/hermes.png"
    entry_name=$(python3 -c 'from linux_desktop_entry import DESKTOP_ENTRY_NAME; print(DESKTOP_ENTRY_NAME)')
    python3 -c 'import os; from linux_desktop_entry import render_desktop_entry; print(render_desktop_entry(os.environ["DESKTOP_EXEC"], os.environ["DESKTOP_ICON"]))' > "$out/share/applications/$entry_name"
    runHook postInstall
  '';

  passthru = {
    inherit (renderer.passthru) packageJsonPath;
  };

  meta = with lib; {
    description = "Native Electron desktop shell for Hermes Agent";
    homepage = "https://github.com/NousResearch/hermes-agent";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "hermes-desktop";
  };
}
