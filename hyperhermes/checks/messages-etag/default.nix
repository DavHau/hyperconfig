# Offline check of ../../modules/core/patches/hermes-dashboard-messages-etag.patch
# on the patched hermes package: the patch's own pytest file
# (tests/hermes_cli/test_session_messages_etag.py; the wheel drops tests/,
# so it is taken from the patch) against the installed modules. An
# unchanged history page answers If-None-Match with a bodiless 304; any
# change the page shows (append, tool row, edit, rewrite) changes the tag,
# a write to another session does not.
{ pkgs, hermesPackage }:
let
  py = "${hermesPackage.hermesVenv}/bin/python3";
  pytestPath = pkgs.python314Packages.makePythonPath [ pkgs.python314Packages.pytest ];
in
pkgs.runCommand "hyperhermes-messages-etag-check" { nativeBuildInputs = [ pkgs.patchutils ]; } ''
  export HOME=$TMPDIR/home
  mkdir -p $HOME src && cd src
  filterdiff -p1 -i 'tests/*' ${../../modules/core/patches/hermes-dashboard-messages-etag.patch} | patch -p1 -F0
  PYTHONPATH=${pytestPath} ${py} -m pytest -q -p no:cacheprovider \
    tests/hermes_cli/test_session_messages_etag.py 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
