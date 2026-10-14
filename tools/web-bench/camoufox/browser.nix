# Camoufox (anti-detect Firefox) from its official release zip, so the
# Python library never downloads a browser. Layout is kept flat in one
# directory: the library reads fontconfig/, fonts/, properties.json and
# version.json beside the executable it is given.
{
  lib,
  stdenv,
  fetchurl,
  libarchive,
  autoPatchelfHook,
  patchelfUnstable,
  wrapGAppsHook3,
  alsa-lib,
  curl,
  dbus-glib,
  gtk3,
  libva,
  libxtst,
  pciutils,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "camoufox";
  version = "156.0.1-beta.36"; # the build camoufox 0.5.8 pins (browser-pin.json)

  src = fetchurl {
    url = "https://github.com/daijro/camoufox/releases/download/v${finalAttrs.version}/camoufox-${finalAttrs.version}-lin.x86_64.zip";
    hash = "sha256-cmN4he5nyTRmrTd4McZHGS+PCPtcb9knneEyC0ndK1M=";
  };
  # bsdtar, not unzip: font file names in the zip are UTF-8 without the flag.
  unpackPhase = ''
    runHook preUnpack
    mkdir source && LC_ALL=C.UTF-8 bsdtar -xf $src -C source
    runHook postUnpack
  '';
  sourceRoot = "source";

  nativeBuildInputs = [
    libarchive
    autoPatchelfHook
    patchelfUnstable
    wrapGAppsHook3
  ];
  buildInputs = [
    gtk3
    alsa-lib
    dbus-glib
    libxtst
  ];
  runtimeDependencies = [
    curl
    pciutils
    libva.out
  ];
  # Firefox uses "relrhack" to process relocations from a fixed offset.
  patchelfFlags = [ "--no-clobber-old-sections" ];

  dontWrapGApps = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/camoufox
    cp -r . $out/lib/camoufox
    # What `camoufox fetch` records; the library checks it against Playwright.
    cat > $out/lib/camoufox/version.json <<EOF
    {"version": "156.0.1", "build": "beta.36", "interface": 1}
    EOF
    runHook postInstall
  '';
  # Wrap in place: the library resolves its data files beside this path.
  postFixup = ''
    wrapGApp $out/lib/camoufox/camoufox --set MOZ_CRASHREPORTER_DISABLE 1
    mkdir -p $out/bin
    ln -s $out/lib/camoufox/camoufox $out/bin/camoufox
  '';

  meta = {
    description = "Anti-detect Firefox build (binary release)";
    homepage = "https://github.com/daijro/camoufox";
    license = lib.licenses.mpl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "camoufox";
  };
})
