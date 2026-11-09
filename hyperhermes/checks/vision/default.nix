# Offline check that every main model gets a working image path, on the
# patched hermes package and the agent settings it is given (./vision.py
# says what it asserts). Both default to hyperhermes' own: the package with
# ../../modules/core/patches and the vision settings of an agent on p0
# (providers.p0 with Qwen declared vision-capable, auxiliary.vision on p0).
# A consumer passes its host's real settings and package instead, so the
# check holds for what is deployed (hyperconfig: checks.hermes-vision).
#
# No network and no model call: fake keys, a stub models.dev catalog
# (./models-dev.json: Claude Opus 5.5 sees images, GLM-5.3 and OpenRouter's
# default auxiliary model do not), clients are only resolved.
{
  pkgs,
  hermesPackage,
  settings ? {
    providers.p0 = {
      base_url = "https://inference.p0.contact/v1";
      key_env = "P0_API_KEY";
      default_model = "qwen";
      models = {
        qwen.supports_vision = true;
        "Qwen3.8-27B-FP8".supports_vision = true;
      };
    };
    auxiliary.vision = {
      provider = "p0";
      model = "qwen";
    };
  },
}:
let
  config = (pkgs.formats.yaml { }).generate "config.yaml" (
    {
      model = {
        provider = "anthropic";
        default = "claude-opus-5-5";
      };
    }
    // builtins.removeAttrs settings [ "model" ]
  );
in
pkgs.runCommand "hyperhermes-vision-check" { } ''
  export HOME=$TMPDIR/home HERMES_HOME=$TMPDIR/home/.hermes
  mkdir -p $HERMES_HOME
  install -m 644 ${config} $HERMES_HOME/config.yaml
  # Fresh (mtime now), so hermes serves it without a refresh.
  install -m 644 ${./models-dev.json} $HERMES_HOME/models_dev_cache.json
  export ANTHROPIC_API_KEY=fake-anthropic OPENROUTER_API_KEY=fake-openrouter P0_API_KEY=fake-p0
  cd $TMPDIR
  ${hermesPackage.hermesVenv}/bin/python3 ${./vision.py} 2>&1 | grep -v -i 'nous' | tee $out
  [ "''${PIPESTATUS[0]}" = 0 ]
''
