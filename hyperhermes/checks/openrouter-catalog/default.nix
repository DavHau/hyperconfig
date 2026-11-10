# Offline check of model_catalog.openrouter_all_models on the patched
# hermes package (../../modules/core/patches/hermes-openrouter-all-models.patch;
# ./openrouter_catalog.py says what it asserts): a fake live OpenRouter
# catalog and a fake curated manifest, no network. Off, the picker list is
# upstream's curated one; on, curated first, then every other tool-capable
# model, and every surface (model_ids, provider_model_ids, the /model
# picker, the desktop/dashboard model options payload) gets the full list.
{ pkgs, hermesPackage }:
pkgs.runCommand "hyperhermes-openrouter-catalog-check" { } ''
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes
  mkdir -p $HERMES_HOME
  export OPENROUTER_API_KEY=fake-openrouter
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./openrouter_catalog.py} 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
