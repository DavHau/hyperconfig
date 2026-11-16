# Offline check of ../../modules/core/patches/hermes-openrouter-no-batch.patch
# (./openrouter_no_batch.py says what it asserts): OpenRouter `:batch` ids
# (async Batch API) leave every OpenRouter catalog and picker row, and an
# OpenRouter `...:batch` model runs as the plain id (agent, fallbacks,
# /model, auxiliary). Fake keys and catalog, no network.
{ pkgs, hermesPackage }:
pkgs.runCommand "hyperhermes-openrouter-no-batch-check" { } ''
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes
  mkdir -p $HERMES_HOME
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./openrouter_no_batch.py} 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
