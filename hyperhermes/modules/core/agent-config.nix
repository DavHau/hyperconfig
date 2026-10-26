# What an agent runs with: config.yaml settings, PATH and the preStart
# scripts that seed the model and the credentials. ./agents.nix applies
# it to the units and to the `hermes` shim, so an interactive session sees
# what the gateway sees.
{
  lib,
  pkgs,
  hlib,
  cfg,
}:
let
  pythonVenv = import ../../lib/python-venv.nix { inherit lib pkgs; };
in
rec {
  hermesPackage = cfg.package;

  # cfg.settings arrives fully merged, the agent's own settings go over
  # it. One leaf is special: skills.external_dirs is the union of every
  # skill root (host-wide and the agent's own skillDirs, then any list an
  # operator set directly), not operator-wins. `lib.recursiveUpdate`
  # replaces lists, so one list would otherwise drop the others.
  settingsFor =
    acfg:
    let
      merged = lib.recursiveUpdate cfg.settings acfg.settings;
    in
    lib.recursiveUpdate merged {
      skills.external_dirs = lib.unique (
        cfg.skillDirs ++ acfg.skillDirs ++ (merged.skills.external_dirs or [ ])
      );
    };

  basePackages = with pkgs; [
    git
    curl
    wget
    jq
    ripgrep
    fd
    file
    unzip
    zip
    gnutar
    xz
    # A build toolchain lets pip compile the odd sdist. binutils also
    # provides the `ld`. ctypes.util.find_library needs that `ld`.
    gcc
    gnumake
    pkg-config
    binutils
    pandoc
    poppler-utils
    ffmpeg
    imagemagick
    sqlite
    yt-dlp
    w3m
    nodejs
    uv
  ];

  # What an agent process runs with, for the units and the `hermes` shim.
  # `home` is the account's home (users.users.<user>.home); this file has
  # no `config`.
  runtime =
    user: home: acfg:
    let
      stateDir = hlib.stateDir user;
    in
    {
      inherit stateDir;
      env = {
        # The account home: hermes-desktop's SSH connection writes its
        # session token under the SSH login home, and `hermes serve`
        # accepts it only under Path.home().
        HOME = home;
        HERMES_HOME = "${stateDir}/.hermes";
        # No HERMES_MANAGED: it locks every setting (hermes_cli/config.py,
        # is_managed). ./agents.nix locks only the Nix keys, through
        # HERMES_MANAGED_DIR.

        # Skills read this to tell a sandboxed agent from a native one.
        HERMES_SANDBOX = "none";
        # The nix-built interpreter loads pip-installed manylinux extension
        # modules. Their NEEDED libs resolve through LD_LIBRARY_PATH.
        LD_LIBRARY_PATH = pythonVenv.wheelLibraryPath;
        # execute_code runs its scripts with the VIRTUAL_ENV python, else
        # with hermes' own sealed interpreter, which lacks the venv's
        # libraries (tools/code_execution_env.py, _resolve_child_python).
        VIRTUAL_ENV = "${stateDir}/.venv";
      };
      # venv root first, so python and pip resolve to the writable
      # interpreter. systemd appends /bin to every `path` entry, so this
      # is the venv ROOT, not its bin dir.
      path = [
        "${stateDir}/.venv"
        hermesPackage
        pkgs.bash
        pkgs.coreutils
        pkgs.git
      ]
      ++ basePackages
      ++ cfg.extraPackages
      ++ acfg.extraPackages;
    };

  # Seed-once model. This writes to config.yaml only when no model is
  # configured. Then it writes a sentinel. So it never clobbers the user's
  # runtime /model choice. It runs in preStart, after config.yaml exists.
  # The Nix settings never contain model keys.
  modelSeedScript =
    stateDir:
    lib.optionalString (cfg.initialModel != null) ''
      sentinel=${stateDir}/.hermes/.model-seeded
      if [ ! -e "$sentinel" ]; then
        ${pkgs.python3.withPackages (ps: [ ps.pyyaml ])}/bin/python3 - \
          ${stateDir}/.hermes/config.yaml <<'SEED'
      import sys, os, yaml
      path = sys.argv[1]
      data = {}
      if os.path.exists(path):
          with open(path) as f:
              data = yaml.safe_load(f) or {}
      if not data.get("model"):
          data["model"] = ${
            builtins.toJSON (
              lib.filterAttrs (_: v: v != null) {
                inherit (cfg.initialModel) provider base_url;
                default = cfg.initialModel.default;
              }
            )
          }
          with open(path, "w") as f:
              yaml.dump(data, f, default_flow_style=False)
      SEED
        touch "$sentinel"
      fi
    '';

  # Strip interpreter-hijacking keys from the writable .env. The gateway
  # imports .env into its process env, and every subprocess inherits it. A
  # persisted PYTHONPATH shadows the venv with the gateway's sealed cp312
  # venv, which causes wrong-ABI imports. The agent can write these keys,
  # so drop them before every start.
  #
  # Then rewrite the credential block (secretEnv, delivered as systemd
  # credentials). hermes loads .env with override=True, which beats the
  # process env, and CLI sessions read .env directly, so credentials must
  # land here. Strip-then-append keeps rotated or removed keys from going
  # stale. The block markers keep their pre-hyperhermes name: deployed
  # .env files carry them.
  envRewriteScript = stateDir: ''
    env_file=${stateDir}/.hermes/.env
    touch "$env_file"
    ${pkgs.gnused}/bin/sed -i -E \
      '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
      "$env_file"
    ${pkgs.gnused}/bin/sed -i \
      '/^# BEGIN hermes-native credentials$/,/^# END hermes-native credentials$/d' \
      "$env_file"
    if [ -n "''${CREDENTIALS_DIRECTORY:-}" ]; then
      {
        echo "# BEGIN hermes-native credentials"
        for f in "$CREDENTIALS_DIRECTORY"/*; do
          [ -f "$f" ] || continue
          printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
        done
        echo "# END hermes-native credentials"
      } >> "$env_file"
    fi
  '';
}
