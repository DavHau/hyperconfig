# Node.js for REA: rea-agents 6.8.0 declares engines
# `^22.23.4 || ^24.22.1 || >=26.12.1` (the 2026-10-21 security releases);
# its doctor fails and `rea setup` refuses an older runtime. nixpkgs ships
# 24.21.0, so this is nixpkgs' own nodejs_24 recipe on the 24.22.1
# tarball. Drop it once nixpkgs' nodejs_24 reaches 24.22.1.
{
  lib,
  fetchurl,
  nodejs_24,
  nodejs-slim_24,
}:
nodejs_24.override {
  nodejs-slim = nodejs-slim_24.overrideAttrs (
    finalAttrs: old: {
      version = "24.22.1";
      src = fetchurl {
        url = "https://nodejs.org/dist/v${finalAttrs.version}/node-v${finalAttrs.version}.tar.xz";
        hash = "sha256-T1N5eWKAza6wwvNY/QS2oWzE+336g7WoyRqdljtDUjE=";
      };
      # Part of 24.22.1's fix (CVE-2026-111497) is a patch to its bundled
      # brotli, and node_zlib.cc uses a constant only that patched copy
      # declares; nixpkgs' shared brotli 1.2.0 has neither.
      configureFlags = lib.filter (flag: !lib.hasPrefix "--shared-brotli" flag) old.configureFlags;
      # Its long test suite already runs on nixpkgs' own 24.x builds of
      # this recipe; a patch release is not worth repeating it here.
      doCheck = false;
    }
  );
}
