{ pkgs, inputs, lib, config, ... }:
# afk: the omp-based harness (profile + patchset) from the local ../afk flake
# checkout. Default package is the non-sandboxed variant (private Nix store);
# afk-nosand is opt-in per host. The bare `omp` and `pi` from spaces'
# agentHarnesses stay beside it as unrelated harnesses; ./omp-p0.nix gives
# bare omp the same models.yml, and every harness shares the p0 key through
# `p0-api-key` (inference-api-key.nix), the TeamClaude key through
# `teamclaude-api-key` (teamclaude-api-key.nix) and the skills in
# ~/.agents/skills.
#
# afk owns its own profile bootstrap (distribution config.yml via
# $OMP_DISTRO_CONFIG, the jj/isolation rules, the superpowers/direnv
# extensions), so this wrapper only adds what afk does NOT ship:
#
# - the models.yml with the p0 provider and the TeamClaude anthropic
#   override (omp-common.nix); `OMP_TEAMCLAUDE=0 afk` starts with omp's
#   builtin anthropic provider instead (api.anthropic.com, own Claude
#   logins), see the preHook,
# - the host-specific always-apply rule (repo layout) and the top-level
#   AGENTS.md,
# - the jobs-hub extension (background-jobs widget, Ctrl+J / /bashjobs),
# - the herdr agent-state extension (herdr-omp-agent-state/).
#
# NOT deployed here, on purpose: config.yml (afk keeps it user-owned and
# writable so runtime settings persist; defaults arrive via $OMP_DISTRO_CONFIG
# below it) and afk's own extensions/rules (its preHook runs after ours, so
# deploying them here would be an overwrite race).
#
# `hyper.afk.pinnedSettings` (the infra-space container turns tools off
# with it) cannot go into afk's distro layer: afk's wrapper exports
# OMP_DISTRO_CONFIG unconditionally after our preHook and offers no hook
# to extend it. It goes in as an omp config overlay (PI_CONFIG_FILES, the
# file form of `--config`), which afk's wrapper leaves alone and omp merges
# ABOVE the user's config.yml: the user (or an agent editing its own
# config.yml) cannot switch these back on.
let
  common = import ./omp-common.nix { inherit pkgs inputs lib config; };
  cfg = config.hyper.afk;
  skill =
    dir:
    lib.fileset.toSource {
      root = dir;
      fileset = dir + "/SKILL.md";
    };
  pinnedSettingsFile = (pkgs.formats.yaml { }).generate "afk-pinned-settings.yml" cfg.pinnedSettings;
in
{
  options.hyper.afk.pinnedSettings = lib.mkOption {
    type = (pkgs.formats.yaml { }).type;
    default = { };
    example = {
      web_search.enabled = false;
    };
    description = "omp settings for afk that override the user's config.yml (an omp config overlay).";
  };

  options.hyper.afk.extraSkills = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = { };
    example = lib.literalExpression "{ forge-prs = ./forge-prs-skill; }";
    description = "Skill name -> directory with its SKILL.md, linked into afk's skills beside the personal ones (a space's own how-tos).";
  };

  config.environment.systemPackages = [
    (inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = inputs.afk.packages.${pkgs.stdenv.hostPlatform.system}.afk;
      preHook = ''
        config_dir="$HOME/.omp/profiles/afk/agent"
        mkdir -p "$config_dir/rules" "$config_dir/extensions" "$config_dir/skills"
        ln -sf ${common.agentsFile} "$config_dir/AGENTS.md"
        # Host-specific always-apply rule (repo layout); the nix/direnv/jj
        # rules live in afk. Rules reach the main loop AND every subagent
        # (omp forwards rules to subagents, unlike AGENTS.md).
        ln -sf ${./default-rules.md} "$config_dir/rules/default-rules.md"
        # Personal skills (see modules/nixos/skills/): symlinked per-skill so
        # user-created skills next to them survive.
        ln -sfn ${skill ./skills/external-scripts} "$config_dir/skills/external-scripts"
        ln -sfn ${skill ./skills/project-init} "$config_dir/skills/project-init"
        # jobs-hub extension: background-bash-jobs widget + Ctrl+J / /bashjobs
        # overlay; Enter prints a job's log into the chat transcript (native
        # scrollback). /jobs is taken by the builtin printout; source + tests
        # in modules/nixos/jobs-hub/.
        ln -sf ${./jobs-hub/jobs-hub.ts} "$config_dir/extensions/jobs-hub.ts"
        # herdr <-> omp agent-state bridge: reports idle/working/blocked to
        # the herdr pane it runs in; inert outside herdr (needs HERDR_ENV=1,
        # HERDR_SOCKET_PATH, HERDR_PANE_ID). Vendored verbatim from what
        # `herdr integration install omp` writes; see herdr-omp-agent-state/.
        ln -sf ${common.herdrOmpExtension} "$config_dir/extensions/herdr-omp-agent-state.ts"
      ''
      # A space's own skills (hyper.afk.extraSkills); nothing elsewhere.
      + lib.concatStrings (
        lib.mapAttrsToList (name: dir: ''
          ln -sfn ${skill dir} "$config_dir/skills/${name}"
        '') cfg.extraSkills
      )
      # After any PI_CONFIG_FILES the caller set: later overlays win.
      + lib.optionalString (cfg.pinnedSettings != { }) ''
        export PI_CONFIG_FILES="''${PI_CONFIG_FILES:+$PI_CONFIG_FILES:}${pinnedSettingsFile}"
      ''
      # TeamClaude or not, per start: omp reads models.yml once and reloads
      # it only when its mtime changes. Both files are store paths (mtime 1),
      # so relinking never makes a running session (or its subagents, which
      # share its registry) switch; each session keeps what it started with.
      + lib.optionalString common.models-needed ''
        if [ "''${OMP_TEAMCLAUDE:-1}" = 0 ]; then
          ln -sf ${common.modelsFileDirect} "$config_dir/models.yml"
          ${lib.optionalString common.teamclaude-enabled ''echo "afk: OMP_TEAMCLAUDE=0, anthropic models go to api.anthropic.com with your own login" >&2''}
        else
          ln -sf ${common.modelsFile} "$config_dir/models.yml"
        fi
      '';
    })
  ];
}
