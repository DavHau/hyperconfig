# The CaptchaKraken browser driver (npm `captchakraken`): finds a captcha
# on a Playwright page, photographs it, and performs the answer. Every
# inference goes through its Python engine (`python -m captchakraken.cli`),
# which here is ./python.nix: the patched engine that never downloads or
# reports anything and talks only to VLLM_BASE_URL.
#
# Upstream's postinstall builds a venv inside the package and pip-installs
# the engine from PyPI, and the driver puts the bundled `python/src` first
# on PYTHONPATH. So the bundled engine is not shipped: `python/` holds only
# links to the Nix engine (`src/captchakraken`, read for models.json) and to
# an interpreter that has it (`.venv/bin/python`, which the driver prefers
# over python3 on PATH).
#
# Source-available licence (internal use permitted), as ./python.nix.
{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
}:
let
  engine = python3.pkgs.callPackage ./python.nix { };
  python = python3.withPackages (_: [ engine ]);
in
buildNpmPackage (finalAttrs: {
  pname = "captchakraken-js";
  version = "3.2.0";

  src = fetchFromGitHub {
    owner = "CaptchaKraken";
    repo = "CaptchaKraken";
    tag = "v${finalAttrs.version}";
    hash = "sha256-ZzpQ6CXGowJGlfRpwqf/eQJTLnkGqyxhLyYyRcGeVpw=";
  };
  sourceRoot = "${finalAttrs.src.name}/js";
  npmDepsHash = "sha256-MpnRtuCRPlEv7NV81dLC56DOhkBQl89nk7c0Gb84URw=";

  # postinstall is the venv bootstrap above.
  npmFlags = [ "--ignore-scripts" ];
  # `npm run build` would run prebuild, which copies the engine in.
  dontNpmBuild = true;
  buildPhase = ''
    runHook preBuild
    node_modules/.bin/tsc
    runHook postBuild
  '';

  # The driver asks the engine to POST each solve's outcome to the
  # endpoint; the patched engine refuses, so the spawn is skipped as well.
  postInstall = ''
    pkg=$out/lib/node_modules/captchakraken
    substituteInPlace $pkg/dist/solver.js --replace-fail \
      "process.env.CAPTCHA_REPORT_OUTCOME === '0'" "true"
    ${lib.getExe python3} - $pkg/package.json <<'EOF'
    import json, sys
    p = json.load(open(sys.argv[1]))
    del p["scripts"]["postinstall"]
    json.dump(p, open(sys.argv[1], "w"), indent=2)
    EOF
    rm -rf $pkg/scripts $pkg/python
    mkdir -p $pkg/python/src $pkg/python/.venv/bin
    ln -s ${engine}/${python3.sitePackages}/captchakraken $pkg/python/src/captchakraken
    ln -s ${lib.getExe python} $pkg/python/.venv/bin/python
  '';

  passthru = { inherit engine python; };

  meta = {
    description = "CaptchaKraken's Playwright captcha driver, on the self-hosted engine";
    homepage = "https://github.com/CaptchaKraken/CaptchaKraken";
  };
})
