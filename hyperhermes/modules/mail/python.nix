# The Python that runs sanitize.py: mailgate, its ./analyze.py workers
# (sys.executable) and the unit tests in checks/mail.
pkgs:
pkgs.python3.withPackages (ps: [
  ps.aiohttp
  (ps.css-inline.overridePythonAttrs (old: {
    patches =
      (old.patches or [ ])
      ++ pkgs.lib.optional (pkgs.lib.versionOlder old.version "0.23.1") ./css-inline-class-attribute.patch;
  }))
])
