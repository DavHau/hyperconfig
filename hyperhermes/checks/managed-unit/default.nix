# Offline check of ../../modules/core/patches/hermes-gateway-managed-unit-only.patch
# on the patched hermes package (./managed_unit.py says what it asserts):
# with HERMES_GATEWAY_MANAGED_UNIT set, clients wait for the agent's unit
# and nothing else starts a gateway for its home. No network, no VM.
{ pkgs, hermesPackage }:
pkgs.runCommand "hyperhermes-managed-unit-check" { } ''
  # Discovery refuses a control dir another user could write.
  umask 077
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes
  mkdir -p $HERMES_HOME
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./managed_unit.py} 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
