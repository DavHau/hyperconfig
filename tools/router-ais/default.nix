{ pkgs }:
pkgs.python3Packages.buildPythonApplication {
  pname = "router-ais";
  version = "0.1.0";
  pyproject = true;
  # Only what setuptools packages; docs/default.nix edits don't rebuild.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./pyproject.toml
      (pkgs.lib.fileset.fileFilter (f: f.hasExt "py") ./router_ais)
    ];
  };

  build-system = [ pkgs.python3Packages.setuptools ];
  dependencies = with pkgs.python3Packages; [
    requests
    pillow
    pytesseract
    cryptography
  ];

  # pytesseract shells out to `tesseract`; the captcha needs only its English data.
  makeWrapperArgs = [ "--prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.tesseract ]}" ];

  pythonImportsCheck = [ "router_ais.cli" ];

  meta = {
    description = "Manage the AIS ZTE F6107A router: login and IPv6 inbound-allow rules";
    mainProgram = "router-ais";
  };
}
