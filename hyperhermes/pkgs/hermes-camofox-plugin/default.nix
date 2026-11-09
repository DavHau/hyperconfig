# hermes' Camofox browser backend, a hermes plugin since hermes v0.23.0
# (Camofox left core, NousResearch/hermes-agent#143146): upstream's
# official `camofox` plugin at the commit hermes v0.23.0's catalog pins
# (plugin-catalog/camofox.yaml), plus hyperhermes' two tools in the
# plugin's `camofox` toolset (./camofox_extras.py, registered by
# ./register-extras.patch):
#   - browser_downloads: the files a page download starts, which
#     camofox-browser captures (GET /tabs/<id>/downloads), saved into the
#     working directory. NousResearch/hermes-agent#52939 asks for it.
#   - browser_solve_captcha: drives the captcha plugin of hyperhermes'
#     camofox-browser (../camofox-browser, POST /tabs/<id>/solve-captcha).
# Both were patches of hermes core (tools/browser_camofox.py) up to
# v0.22.5. ./native-vision.patch: browser_vision attaches the screenshot
# for a main model with native vision (was a hunk of the core patch
# hermes-vision-every-model). The vault (browser_vault on the Camofox tab) is upstream's now:
# core's browser page backend seam plus the plugin's camofox_vault.py.
#
# The plugin needs `requests` only, which the hermes venv has. hermes
# imports it as a package from $HERMES_HOME/plugins/camofox (the browser
# module links it there).
#
# passthru.installRecord: the entry of plugins/.install-metadata.json that
# `hermes plugins install camofox` would write, for the copy linked at
# plugins/camofox: the official catalog entry at its reviewed pin. `pinned`
# does not hold a catalog install back: `hermes plugins update camofox`
# re-pins to the live catalog's sha (hermes_cli/plugins_cmd_catalog.py
# cmd_update_catalog). That fails on the read-only store copy, and the
# browser module keeps plugins.auto_apply off; a hermes bump re-pins here.
# hermes accepts the plugin's browser page backend, through which
# browser_vault fills the Camofox tab, only from a plugin bundled with it
# or with such a record (hermes_cli/plugins_cmd_catalog.py
# login_backend_provenance_error).
{
  lib,
  runCommand,
  fetchFromGitHub,
  writeText,
}:
let
  src = fetchFromGitHub {
    owner = "NousResearch";
    repo = "hermes-official-plugins";
    rev = "1138f25c8b7b5a8fb882b3161e248f29abbd1a46";
    hash = "sha256-t9U2/4M5h25Poeg+A0nusjMNwqWv9Sw19zCBz5aaK7I=";
  };
  repo = "https://github.com/NousResearch/hermes-official-plugins";
  installRecord = writeText "hermes-camofox-install-record.json" (
    builtins.toJSON {
      pinned = true;
      revision = src.rev;
      source = repo;
      catalog = {
        name = "camofox";
        inherit repo;
        tier = "official";
        pin = src.rev;
        sha = src.rev;
      };
    }
  );
in
runCommand "hermes-camofox-plugin-1.1.0"
  {
    passthru = { inherit src installRecord; };
    meta.license = lib.licenses.mit;
  }
  ''
    mkdir $out
    # The plugin's files, not its tests or packaging metadata.
    cp ${src}/camofox/{__init__.py,plugin.yaml,LICENSE,camofox_*.py} $out/
    cp ${./camofox_extras.py} $out/camofox_extras.py
    chmod -R u+w $out
    cd $out
    patch -p1 < ${./register-extras.patch}
    patch -p1 < ${./native-vision.patch}
  ''
