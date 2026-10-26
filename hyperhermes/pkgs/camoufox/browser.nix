# Camoufox (anti-detect Firefox) from its official release zip, so no
# library (camoufox Python, camofox-browser) downloads a browser. Layout is
# kept flat in one directory: the libraries read fontconfig/, fonts/,
# properties.json and version.json beside the executable they are given.
#
# The default is the build camoufox 0.5.8 pins (browser-pin.json);
# consumers pinned to another build override version and hash.
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
  version ? "156.0.1-beta.36",
  hash ? "sha256-cmN4he5nyTRmrTd4McZHGS+PCPtcb9knneEyC0ndK1M=",
}:
let
  # "156.0.1-beta.36" -> 156.0.1, beta.36
  parts = lib.splitString "-" version;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "camoufox";
  inherit version;

  src = fetchurl {
    url = "https://github.com/daijro/camoufox/releases/download/v${finalAttrs.version}/camoufox-${finalAttrs.version}-lin.x86_64.zip";
    inherit hash;
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
    # What `camoufox fetch` records; the libraries check it against their
    # supported range. camoufox-js reads `release` and downloads a browser
    # when it finds none; the Python library reads either key.
    cat > $out/lib/camoufox/version.json <<EOF
    {"version": "${lib.elemAt parts 0}", "build": "${lib.elemAt parts 1}", "release": "${lib.elemAt parts 1}", "interface": 1}
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
