{ pkgs }:
pkgs.python3Packages.buildPythonApplication {
  pname = "router-cm-beryl";
  version = "0.1.0";
  pyproject = true;
  # Only what setuptools packages (incl. package-data); no docs, no __pycache__.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./pyproject.toml
      (pkgs.lib.fileset.fileFilter (
        f: f.hasExt "py" || pkgs.lib.hasPrefix "lan6-fallback." f.name
      ) ./router_cm_beryl)
    ];
  };

  build-system = [ pkgs.python3Packages.setuptools ];

  # The router only offers password auth (dropbear); sshpass feeds it from $SSHPASS.
  makeWrapperArgs = [ "--prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sshpass pkgs.openssh ]}" ];

  pythonImportsCheck = [ "router_cm_beryl.cli" ];

  meta = {
    description = "Manage IPv6 inbound-allow firewall rules on the GL.iNet Beryl (GL-MT3000) over ssh + uci";
    mainProgram = "router-cm-beryl";
  };
}
