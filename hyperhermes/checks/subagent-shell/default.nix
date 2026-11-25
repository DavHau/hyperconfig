# Offline check of ../../modules/core/patches/hermes-subagent-own-shell.patch
# (./subagent_shell.py says what it asserts): three parallel delegate_task
# children on the local terminal backend each keep their own shell state
# (exports, unsets), start from the parent's, and never reach the parent or
# a sibling; their environments go with them. No LLM, no network.
{ pkgs, hermesPackage }:
pkgs.runCommand "hyperhermes-subagent-shell-check" { } ''
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes TERMINAL_ENV=local TERMINAL_CWD=$TMPDIR
  mkdir -p $HERMES_HOME
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./subagent_shell.py} 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
