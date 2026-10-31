# rea-agents (REA, "Reverse Engineer Anything", github.com/morluto/rea):
# one CLI (`rea`) and stdio MCP server (`rea mcp`) over decompilers,
# Android/.NET/JS/wasm/firmware/capture tools. Built from the published
# npm tarball, whose dist/ is already compiled (a source build needs the
# repo's turbo artifact pipeline), with a vendored lock: the tarball has
# none, so ./package-lock.json is upstream's repo lock pruned to the
# runtime dependencies (`npm install --package-lock-only` on the
# postPatch package.json below). Update: bump version and hash, redo the
# lock that way, refresh npmDepsHash.
#
# Left out: the optional `frida` dependency. Its install script downloads
# a prebuilt binding (or the frida-core devkit to build one), which a
# sandboxed build cannot. Without it REA's Frida tools (attach/spawn
# instrumentation, frida_* workflows) report frida unavailable; everything
# else works. @lydell/node-pty, for PTY process capture, ships its Linux
# binding prebuilt in @lydell/node-pty-linux-x64.
#
# `rea` runs on ./nodejs.nix (engines needs >=24.22.1) with procps' `ps`
# on PATH: REA refuses its Linux process workflows without a procps ps.
# passthru: nodejs and entrypoint (for an MCP `command`/`args` without
# the wrapper) and skills, the root holding the bundled
# reverse-engineer-anything skill with its references/.
{
  lib,
  buildNpmPackage,
  callPackage,
  fetchurl,
  jq,
  autoPatchelfHook,
  makeWrapper,
  stdenv,
  procps,
}:
let
  nodejs = callPackage ./nodejs.nix { };
in
buildNpmPackage (finalAttrs: {
  pname = "rea-agents";
  version = "6.8.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/rea-agents/-/rea-agents-${finalAttrs.version}.tgz";
    hash = "sha256-jVQux2qcs1BYS2CmycCIcG/4EtW7WwlMIMlbbcJWmLs=";
  };
  npmDepsHash = "sha256-XoxPtBW6tpQCiHS2Iq3dMNf/D1ThcFe/7aWNlAfNuBI=";

  inherit nodejs;

  # Runtime dependencies only: the dev tooling, its overrides and the
  # repo scripts (prepare/prepack) are not part of an installed package,
  # and frida is dropped (see above).
  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies, .scripts, .optionalDependencies, .allowScripts, ."lint-staged", .overrides)' \
      package.json > package.json.new
    mv package.json.new package.json
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

  # node-pty's prebuilt Linux binding links libstdc++ (npm installs only
  # this platform's prebuild).
  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [ stdenv.cc.cc.lib ];

  postInstall = ''
    for bin in rea rea-agents; do
      wrapProgram $out/bin/$bin --prefix PATH : ${
        lib.makeBinPath [
          nodejs
          procps
        ]
      }
    done
  '';

  passthru = {
    inherit nodejs;
    entrypoint = "${finalAttrs.finalPackage}/lib/node_modules/rea-agents/scripts/rea.mjs";
    skills = "${finalAttrs.finalPackage}/lib/node_modules/rea-agents/skills";
  };

  meta = {
    description = "Reverse engineer anything from your terminal or agent with one CLI and MCP server";
    homepage = "https://github.com/morluto/rea";
    license = lib.licenses.mit;
    mainProgram = "rea";
    platforms = [ "x86_64-linux" ];
  };
})
