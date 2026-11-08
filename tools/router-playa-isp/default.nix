{ pkgs }:
pkgs.python3Packages.buildPythonApplication {
  pname = "router-playa-isp";
  version = "0.1.0";
  pyproject = true;
  # Only what setuptools packages; no docs, no __pycache__.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./pyproject.toml
      (pkgs.lib.fileset.fileFilter (f: f.hasExt "py") ./router_playa_isp)
    ];
  };

  build-system = [ pkgs.python3Packages.setuptools ];

  pythonImportsCheck = [ "router_playa_isp.cli" ];

  meta = {
    description = "Converge the DHCP pool and reservations of playa's ISP router (Orange Livebox Fibra) over its web UI";
    mainProgram = "router-playa-isp";
  };
}
