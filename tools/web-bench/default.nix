{ python3Packages, lib, callPackage, chromium, xvfb-run }:
let
  camoufox-browser = callPackage ./camoufox/browser.nix { };
  camoufox = python3Packages.callPackage ./camoufox/python.nix { };
in
python3Packages.buildPythonApplication {
  pname = "web-bench";
  version = "0.1.0";
  pyproject = true;
  src = ./.;

  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [
    requests
    curl-cffi
    playwright
    camoufox
  ];

  # Browsers come from Nix, never from a Playwright/Camoufox download.
  # WEB_BENCH_BIN lets `launch` hand systemd-run this exact store path.
  makeWrapperArgs = [
    "--set WEB_BENCH_CHROMIUM ${lib.getExe chromium}"
    "--set WEB_BENCH_CAMOUFOX ${camoufox-browser}/lib/camoufox/camoufox"
    "--set WEB_BENCH_BIN ${placeholder "out"}/bin/web-bench"
    "--set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1"
    "--prefix PATH : ${lib.makeBinPath [ xvfb-run ]}"
  ];

  pythonImportsCheck = [ "web_bench.cli" ];

  meta = {
    description = "Rate-limited anti-bot benchmark of web fetch setups for the hermes agents";
    mainProgram = "web-bench";
  };
}
