# What an agent runs with: the patched hermes package, config.yaml
# settings, PATH and skill set. agents.nix applies it to the units and to
# the `hermes` shim, so an interactive session sees what the gateway sees.
{
  lib,
  pkgs,
  inputs,
  hlib,
  cfg,
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  # Every bundled skill of the spaces flake, in one root (spaces
  # packages/agent-skills). A host-scoped skill stays out of this root;
  # the host that wants it adds its own root through
  # cfg.settings.skills.external_dirs, the union below.
  #
  # Each integration skill (caldav, contacts, github, location, mail,
  # offline-wiki, proton, signal) names only spaces gateway tools, never a
  # CLI, and forbids the third-party path for its domain (signal-cli,
  # himalaya, `gh`, khal/vdirsyncer) that hermes' own bundled skills point
  # at. None gates itself on `requires_tools`: the agent snapshots its tool
  # registry before MCP discovery finishes, so such a gate hid them all.
  agentSkills = inputs.spaces.packages.${system}.agent-skills;
  skillsRoot = "${agentSkills}/share/skills";
in
rec {
  # The agent runs these skill CLIs by bare name. They come from the skill
  # packages, so the list cannot drift from skills/<name>/SKILL.md.
  skillCliPackages = agentSkills.skillPackages;

  # cfg.settings arrives fully merged. One leaf is special:
  # skills.external_dirs is a union with the shipped skills root first,
  # not operator-wins. `lib.recursiveUpdate` replaces lists, so an
  # operator list would otherwise drop the built-in skills.
  settings = lib.recursiveUpdate cfg.settings {
    skills.external_dirs = lib.unique ([ skillsRoot ] ++ (cfg.settings.skills.external_dirs or [ ]));
  };

  basePackages =
    (with pkgs; [
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
    ])
    ++ skillCliPackages;

  # hermes patches cannot ride an overrideAttrs: upstream seals the
  # venv from a source filter rooted in its own nix/ directory, and the
  # built package only symlinks into that venv. So the package is built
  # again through upstream's own nix/packages.nix, with upstream's own
  # inputs. The hermes-agent nixpkgs input follows ours, so the deps are
  # the same store paths; only the hermes-agent wheel and the venv
  # rebuild.
  #
  # Not from a patched copy of the source (pkgs.applyPatches): importing
  # nix/packages.nix from it would be import-from-derivation. Instead the
  # uv2nix input that packages.nix receives gets one more overlay that
  # patches the hermes-agent wheel. The wheel source drops tests/, so
  # filterdiff drops the test hunks.
  hermesInputs = inputs.hermes-agent.inputs;
  hermesPkgs = hermesInputs.nixpkgs.legacyPackages.${system};
  hermesWheelPatches = [
    ./patches/hermes-auth-bare-named-provider.patch
    ./patches/hermes-gateway-restart-foreign-unit.patch
    ./patches/hermes-camofox-browser-downloads.patch
  ];
  patchHermesWheel = _final: prev: {
    hermes-agent = prev.hermes-agent.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ hermesPkgs.patchutils ];
      postPatch =
        (old.postPatch or "")
        + lib.concatMapStrings (p: ''
          filterdiff -p1 -x 'tests/*' ${p} | patch -p1
        '') hermesWheelPatches;
    });
  };
  uv2nixPatched = lib.recursiveUpdate hermesInputs.uv2nix {
    lib.workspace.loadWorkspace =
      args:
      let
        workspace = hermesInputs.uv2nix.lib.workspace.loadWorkspace args;
      in
      workspace
      // {
        mkPyprojectOverlay =
          overlayArgs: lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) patchHermesWheel;
      };
  };

  hermesUpstream =
    (import "${inputs.hermes-agent}/nix/packages.nix" {
      # rev = null: no HERMES_REVISION, so the wrapper does not change with
      # this flake's revision. Upstream reads `inputs.self.rev or null`.
      inputs = hermesInputs // {
        self = { };
        uv2nix = uv2nixPatched;
      };
    }).perSystem
      {
        pkgs = hermesPkgs;
        inherit lib;
        inputs'.npm-lockfile-fix.packages.default = hermesInputs.npm-lockfile-fix.packages.${system}.default;
      };

  hermesPackage = hermesUpstream.packages.default;

  # What an agent process runs with, for the units and the `hermes` shim.
  # `home` is the account's home (users.users.<user>.home); this file has
  # no `config`.
  runtime =
    user: home:
    let
      pythonVenv = import ./python-venv.nix { inherit lib pkgs; };
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
        # is_managed). agents.nix locks only the Nix keys, through
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
      ++ cfg.extraPackages;
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
  # Then rewrite the credential block. hermes loads .env with
  # override=True, which beats the process env, and CLI sessions read .env
  # directly, so credentials must land here. Strip-then-append keeps
  # rotated or removed keys from going stale.
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
