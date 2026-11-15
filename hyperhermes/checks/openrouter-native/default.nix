# Offline check of model_catalog.openrouter_exclude_native on the patched
# hermes package (../../modules/core/patches/hermes-openrouter-exclude-native.patch;
# ./openrouter_native.py says what it asserts): fake keys and a fake live
# OpenRouter catalog, no network. With an Anthropic key, OpenRouter's
# anthropic/* models leave the catalog and every OpenRouter request for
# one (runtime resolution, delegate_task children, the agent constructor
# and its fallback chain, auxiliary clients, /model) runs on anthropic;
# without the key, or with the option unset, nothing changes.
{ pkgs, hermesPackage }:
pkgs.runCommand "hyperhermes-openrouter-native-check" { } ''
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes
  mkdir -p $HERMES_HOME
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./openrouter_native.py} 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
