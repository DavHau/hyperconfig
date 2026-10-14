# The camoufox Python library (fingerprint generation + launch options) with
# every runtime download removed: the browser comes from ./browser.nix via
# executable_path, fpgen's model is a fixed-output fetch baked into fpgen,
# and the default uBlock addon is excluded by the caller.
{
  lib,
  python,
  buildPythonPackage,
  fetchPypi,
  fetchurl,
  unzip,
  poetry-core,
  click,
  httpx,
  indexed-zstd,
  inquirer,
  language-tags,
  numpy,
  orjson,
  platformdirs,
  playwright,
  pysocks,
  pyyaml,
  requests,
  rich,
  rich-click,
  screeninfo,
  typing-extensions,
  ua-parser,
  zstandard,
}:
let
  # The model camoufox 0.5.8 pins in camoufox/fpgen-model.json.
  fpgenModel = fetchurl {
    url = "https://github.com/scrapfly/fingerprint-generator/releases/download/model-2/2026/model-release.zip";
    sha256 = "6530b8322cdaa4ec042921c8d9a0369a0e6e0269ba636c01a7203e4a2f109936";
  };

  fpgen = buildPythonPackage rec {
    pname = "fpgen";
    version = "1.3.0";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-AXzBXq83PswEEEvI49QX1KJIqcPD6TcW+UrF62QqU0w=";
    };
    build-system = [ poetry-core ];
    dependencies = [
      click
      httpx
      indexed-zstd
      numpy
      orjson
      zstandard
    ];
    # fpgen re-downloads (TLS verification off) when its model is older than
    # five weeks; store files are always "old", and the model is pinned here.
    postPatch = ''
      substituteInPlace fpgen/pkgman.py --replace-fail \
        'return all(datetime.fromtimestamp(f.stat().st_mtime) >= cutoff for f in file_list)' \
        'return True'
    '';
    nativeBuildInputs = [ unzip ];
    postInstall = ''
      unzip -d $out/${python.sitePackages}/fpgen/data ${fpgenModel}
    '';
    pythonImportsCheck = [ "fpgen" ];
  };
in
buildPythonPackage rec {
  pname = "camoufox";
  version = "0.5.8";
  pyproject = true;
  src = fetchPypi {
    inherit pname version;
    hash = "sha256-QK0jpelWSGLfJVCuU6HfMBa2Y9pSmWlP/9hZTsqJ4tI=";
  };
  build-system = [ poetry-core ];
  dependencies = [
    fpgen
    inquirer
    language-tags
    numpy
    orjson
    platformdirs
    playwright
    pysocks
    pyyaml
    requests
    rich
    rich-click
    screeninfo
    typing-extensions
    ua-parser
  ];
  # nixpkgs ships Playwright 1.63; upstream caps <1.63 as untested.
  pythonRelaxDeps = [ "playwright" ];
  # The pinned model is already inside fpgen (read-only store); skip the
  # installer, which would download it or try to re-date the files.
  postPatch = ''
    substituteInPlace camoufox/fpgen_model.py --replace-fail \
      '    if os.getenv(CUSTOM_MODEL_ENV):' \
      '    if True:  # Nix: fpgen ships the pinned model'
  '';
  pythonImportsCheck = [ "camoufox" ];
  postInstallCheck = ''
    PYTHONPATH=$out/${python.sitePackages}:$PYTHONPATH ${python.interpreter} -c 'from camoufox.fpgen_model import is_pinned; assert is_pinned(), "fpgen model is not the pinned one"'
  '';
  passthru = { inherit fpgen; };

  meta = {
    description = "Launch-option and fingerprint library for the Camoufox browser";
    homepage = "https://github.com/daijro/camoufox";
    license = lib.licenses.mit;
  };
}
