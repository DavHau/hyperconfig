# Offline check of the vault's hosted card-field fill on the patched hermes
# package (the three hermes-vault-payment patches in modules/core/patches): the
# patches' own pytest files (the wheel drops tests/, so they are taken from
# the patches) against the installed modules: consent only for a checkout
# that can take a card (#126889), card tokens written only into a known
# processor's frame embedded directly in the bound page (#136981), the same
# over a plugin page backend (Camofox), refused for a frame from another
# origin, a nested one, srcdoc/about:blank/data: frames and a processor URL
# whose document is not the processor's; no card value in a result. The
# browser check (../browser) runs it against a real Camofox. No network.
#
# Isolation (hermes-vault-fill-isolated-world.patch): every fill script runs
# in a CDP isolated world after a value-free check; run in a node document
# whose every built-in is hooked and walks fn.caller, the scripts leak
# nothing (the shipped #136981 guard does: the control), and a frame or page
# that moves to the attacker after the check gets nothing. The upstream
# test files whose fakes the patch extends run too.
{
  pkgs,
  hermesPackage,
  hermesSrc,
}:
let
  py = "${hermesPackage.hermesVenv}/bin/python3";
  pytestPath = pkgs.python314Packages.makePythonPath [ pkgs.python314Packages.pytest ];
  patches = ../../modules/core/patches;
in
pkgs.runCommand "hyperhermes-vault-payment-frames-check" { nativeBuildInputs = [ pkgs.patchutils pkgs.nodejs ]; } ''
  export HOME=$TMPDIR/home
  mkdir -p $HOME $TMPDIR/hermes src && cd src
  export HERMES_HOME=$TMPDIR/hermes
  # The upstream test files these patches touch, as v0.23.0 has them (the
  # wheel has no tests/), then every patch's test hunks in package.nix order.
  for t in test_browser_vault_origin_guard test_bot_desktop_browser_fence test_browser_vault_page_backend; do
    mkdir -p tests/tools && cp ${hermesSrc}/tests/tools/$t.py tests/tools/ && chmod u+w tests/tools/$t.py
  done
  for p in hermes-vault-payment-consent-needs-card hermes-vault-payment-iframe-fill hermes-vault-payment-iframe-page-backend hermes-vault-fill-isolated-world; do
    filterdiff -p1 -i 'tests/*' -x 'tests/tools/test_browser_vault.py' ${patches}/$p.patch | patch -p1 -F0
  done
  PYTHONPATH=${pytestPath} ${py} -m pytest -q -p no:cacheprovider \
    tests/tools/test_browser_vault_payment_consent.py \
    tests/tools/test_vault_payment_iframe.py \
    tests/tools/test_vault_payment_iframe_page_backend.py \
    tests/tools/test_vault_fill_hostile_page.py \
    tests/tools/test_browser_vault_origin_guard.py \
    tests/tools/test_bot_desktop_browser_fence.py \
    tests/tools/test_browser_vault_page_backend.py 2>&1 | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
