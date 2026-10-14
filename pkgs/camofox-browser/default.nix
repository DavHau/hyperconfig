# camofox-browser: the REST server around Camoufox that hermes' Camofox
# browser backend talks to. Nothing is fetched at runtime: the browser is a
# Nix Camoufox (CAMOUFOX_EXECUTABLE), the default uBlock addon is excluded
# by the caller, and no install script runs.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs,
}:
buildNpmPackage (finalAttrs: {
  pname = "camofox-browser";
  version = "1.18.1";

  src = fetchFromGitHub {
    owner = "jo-inc";
    repo = "camofox-browser";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ZB9K8bZxvyW+wodLMFGvAY2FlyJX8etQ4Wu8vKJFbLs=";
  };
  npmDepsHash = "sha256-Ff4ErNqHVQ3C59a2M21IE5FkPvcO0r4LNFHF6D/QhuA=";

  patches = [ ./challenge-wait.patch ];

  # Crash reports go to a public relay unless opted out: off unless opted
  # in. The YouTube plugin shells out to a downloaded yt-dlp.
  #
  # The lockfile disagrees with `overrides` on the dev tree (jest's glob),
  # so npm ci would ask the registry; nothing here needs the dev tree, so
  # it and the overrides go.
  postPatch = ''
    substituteInPlace lib/config.js --replace-fail \
      "process.env.CAMOFOX_CRASH_REPORT_ENABLED !== 'false'" \
      "process.env.CAMOFOX_CRASH_REPORT_ENABLED === 'true'"
    substituteInPlace camofox.config.json --replace-fail \
      '"youtube": { "enabled": true }' '"youtube": { "enabled": false }'
    ${lib.getExe nodejs} -e '
      const fs = require("fs");
      const p = JSON.parse(fs.readFileSync("package.json"));
      delete p.overrides;
      delete p.devDependencies;
      fs.writeFileSync("package.json", JSON.stringify(p, null, 2));
      const l = JSON.parse(fs.readFileSync("package-lock.json"));
      delete l.packages[""].devDependencies;
      for (const [k, v] of Object.entries(l.packages)) if (v.dev) delete l.packages[k];
      fs.writeFileSync("package-lock.json", JSON.stringify(l, null, 2));
    '
  '';

  # The postinstall downloads Camoufox, and no native module is used.
  npmFlags = [ "--ignore-scripts" ];
  npmRebuildFlags = [ "--ignore-scripts" ];
  # Nothing to compile; the Makefile only downloads a browser.
  dontBuild = true;

  meta = {
    description = "REST browser server for AI agents on Camoufox";
    homepage = "https://github.com/jo-inc/camofox-browser";
    license = lib.licenses.mit;
    mainProgram = "camofox-browser";
  };
})
