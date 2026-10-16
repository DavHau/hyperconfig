{ python3Packages, lib, callPackage, chromium, xvfb-run }:
let
  camoufox-browser = callPackage ../../pkgs/camoufox/browser.nix { };
  camoufox = python3Packages.callPackage ../../pkgs/camoufox/python.nix { };
  captchakraken = python3Packages.callPackage ../../pkgs/captchakraken/python.nix { };
in
python3Packages.buildPythonApplication {
  pname = "web-bench";
  version = "0.1.0";
  pyproject = true;
  # The Python package only: edits to the .nix files, __pycache__ or
  # result links leave it unchanged.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      (lib.fileset.fileFilter (f: f.hasExt "py") ./web_bench)
    ];
  };

  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [
    requests
    curl-cffi
    playwright
    camoufox
    captchakraken
  ];

  # Browsers come from Nix, never from a Playwright/Camoufox download.
  # WEB_BENCH_BIN lets `launch` hand systemd-run this exact store path.
  # CaptchaKraken talks to llama-server on vit
  # (modules/nixos/captchakraken-server.nix); VLLM_BASE_URL overrides it.
  makeWrapperArgs = [
    "--set WEB_BENCH_CHROMIUM ${lib.getExe chromium}"
    "--set WEB_BENCH_CAMOUFOX ${camoufox-browser}/lib/camoufox/camoufox"
    "--set WEB_BENCH_BIN ${placeholder "out"}/bin/web-bench"
    "--set PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1"
    "--set-default VLLM_BASE_URL http://vit.d:8096/v1"
    "--set CAPTCHA_LORA_NAME CaptchaKraken/CaptchaKraken-v1.2-GGUF"
    "--prefix PATH : ${lib.makeBinPath [ xvfb-run ]}"
  ];

  pythonImportsCheck = [ "web_bench.cli" ];

  meta = {
    description = "Rate-limited anti-bot benchmark of web fetch setups for the hermes agents";
    mainProgram = "web-bench";
  };
}
