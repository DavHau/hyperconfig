# The CaptchaKraken engine (OpenCV grid detection + the HTTP planner) as a
# client of our own llama-server on vit (modules/nixos/captchakraken-server.nix).
# Never downloads or reports anything: no Hub prompt lookup, no outcome POST,
# no local vLLM autostart, and the pip/hf `fetch`/`server` commands removed.
# Source-available licence (internal use permitted); no nixpkgs licence fits,
# and marking it unfree would need allowUnfree for `nix build .#web-bench`.
{
  python,
  buildPythonPackage,
  fetchPypi,
  numpy,
  opencv-python-headless,
  pillow,
  pydantic,
  python-dotenv,
  requests,
}:
let
  # The mouse paths (LGPL-3.0-or-later).
  cursory = buildPythonPackage rec {
    pname = "cursory";
    version = "2.0.0";
    format = "wheel";
    src = fetchPypi {
      inherit pname version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-FCAT9r21+QW3bCSVWhZ5AaElgOh1iajeWZ0QB/eQjjg=";
    };
    dependencies = [ numpy ];
    pythonRelaxDeps = [ "numpy" ];
    pythonImportsCheck = [ "cursory" ];
  };
in
buildPythonPackage rec {
  pname = "captchakraken";
  version = "3.2.0";
  format = "wheel";
  src = fetchPypi {
    inherit pname version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-/JzSL7rUW1d8W3zYXWggbtbo9gSUVAUcYeu7ACj2Vwk=";
  };
  dependencies = [
    cursory
    numpy
    opencv-python-headless
    pillow
    pydantic
    python-dotenv
    requests
  ];
  # Upstream pins every dependency exactly; nixpkgs has its own versions.
  pythonRelaxDeps = true;

  # A wheel has no source tree to patch before install.
  postInstall = ''
    pkg=$out/${python.sitePackages}/captchakraken
    substituteInPlace $pkg/prompts.py --replace-fail \
      'os.getenv(_DISABLE_FETCH_ENV, "0") != "1"' 'False'
    substituteInPlace $pkg/planner.py --replace-fail \
      'os.getenv(_REPORT_OUTCOME_ENV, "1") == "0"' 'True'
    substituteInPlace $pkg/config.py --replace-fail \
      'os.getenv("CAPTCHA_KRAKEN_AUTOSTART", "1") != "0"' 'False'
    substituteInPlace $pkg/cli.py \
      --replace-fail '    "server": _server,' "" \
      --replace-fail '    "fetch": _fetch,' "" \
      --replace-fail '    "update": _fetch,' ""
    rm $pkg/updater.py
  '';
  pythonImportsCheck = [
    "captchakraken"
    "captchakraken.page_solver"
  ];

  meta = {
    description = "Captcha-solving engine for a self-hosted CaptchaKraken model";
    homepage = "https://github.com/CaptchaKraken/CaptchaKraken";
    mainProgram = "captchakraken";
  };
}
