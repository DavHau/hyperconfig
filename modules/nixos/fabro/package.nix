# Fabro (https://github.com/fabro-sh/fabro) built entirely from source:
#
# 1. `node-modules`: fixed-output derivation running `bun install
#    --frozen-lockfile` against the repo's bun.lock (workspaces: apps/*,
#    lib/packages/*).
# 2. Main derivation: bun-bundles the web SPA (apps/fabro-web), mirrors
#    dist/ into lib/crates/fabro-spa/assets (what `cargo dev spa refresh`
#    does), then builds the Rust workspace default member `fabro-cli`,
#    which embeds the SPA via rust-embed and yields the single `fabro`
#    binary. Graphviz, openssl, and libgit2 are vendored by upstream and
#    compiled from source as part of the cargo build.
{ pkgs }:
let
  inherit (pkgs) lib;
  version = "0.254.0";

  src = pkgs.fetchFromGitHub {
    owner = "fabro-sh";
    repo = "fabro";
    tag = "v${version}";
    hash = "sha256-5B2jraewHK6j88nNjafhXNJuBU14/ZSTT6X408D7aVc=";
  };

  node-modules = pkgs.stdenvNoCC.mkDerivation {
    pname = "fabro-node-modules";
    inherit version src;

    nativeBuildInputs = [ pkgs.bun ];

    dontConfigure = true;
    dontFixup = true; # fixup would alter the fixed output

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bun install --frozen-lockfile --no-progress --ignore-scripts
      runHook postBuild
    '';

    # Keep every node_modules dir (root + per-workspace); workspace
    # symlinks are relative, so they resolve again once copied back into
    # an identical source tree.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      find . -type d -name node_modules -prune | while read -r dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
      runHook postInstall
    '';

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-FnyMN8Kx3sIEiNg94ZoDMjif/aV/5ogvufNlgDddCy4=";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "fabro";
  inherit version src;

  cargoHash = "sha256-zqL2Xtm3NZe+P1247J43fisZYfxqs3YZGCfq1BqHYZQ=";

  nativeBuildInputs = [
    pkgs.bun
    pkgs.nodejs
    pkgs.autoPatchelfHook
    pkgs.cmake # aws-lc-sys
    pkgs.perl # openssl-src (vendored openssl)
  ];

  buildInputs = [ pkgs.stdenv.cc.cc.lib ];

  # autoPatchelfHook is only used explicitly on node_modules below; the
  # produced fabro binary itself must not be touched at fixup time before
  # we know it needs it (it doesn't — plain glibc dynamic links).
  dontAutoPatchelf = true;

  # Build the SPA and mirror it into fabro-spa/assets before cargo runs.
  preBuild = ''
    cp -a ${node-modules}/. .
    chmod -R u+w .

    # Only the tailwind oxide native module runs during the SPA build;
    # other prebuilt npm blobs (remotion ffmpeg, musl oxide variants,
    # etc.) are unused and some are unpatchable, so patch narrowly.
    # .bin scripts need real interpreters for their shebangs.
    autoPatchelf node_modules/.bun/@tailwindcss+oxide-linux-*-gnu*
    patchShebangs node_modules

    export HOME=$TMPDIR
    (cd apps/fabro-web && bun run build)

    rm -rf lib/crates/fabro-spa/assets
    mkdir -p lib/crates/fabro-spa/assets
    cp -a apps/fabro-web/dist/. lib/crates/fabro-spa/assets/
    # rust-embed excludes *.map, but drop them anyway to keep the
    # embedded set identical to `cargo dev spa refresh`.
    find lib/crates/fabro-spa/assets -name '*.map' -delete
  '';

  cargoBuildFlags = [ "--package" "fabro-cli" ];

  # Test suite expects twin servers / network and a dev checkout.
  doCheck = false;

  meta = {
    description = "Open source dark software factory: agent workflow graphs with human gates";
    homepage = "https://github.com/fabro-sh/fabro";
    changelog = "https://github.com/fabro-sh/fabro/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "fabro";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
