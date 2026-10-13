# What a native agent runs with: the patched hermes package, config.yaml
# settings, .env entries, PATH and skill set. native.nix (units) and
# cli.nix (`hermes` shim) both read this, so an interactive session sees
# what the gateway sees. Vendored from spaces 6d744780
# modules/nixos/hermes/agent-config.nix (native subset).
{
  lib,
  pkgs,
  inputs,
  hlib,
  cfg,
  hostName,
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  # Every bundled skill spaces ships, in one root (spaces
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
  inherit agentSkills;

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

  # hermes_cli patches cannot ride an overrideAttrs: upstream seals the
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
  # filterdiff keeps only the hermes_cli hunks.
  hermesInputs = inputs.hermes-agent.inputs;
  hermesPkgs = hermesInputs.nixpkgs.legacyPackages.${system};
  hermesWheelPatches = [
    ./patches/hermes-auth-bare-named-provider.patch
    ./patches/hermes-gateway-restart-foreign-unit.patch
  ];
  patchHermesWheel = _final: prev: {
    hermes-agent = prev.hermes-agent.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ hermesPkgs.patchutils ];
      postPatch =
        (old.postPatch or "")
        + lib.concatMapStrings (p: ''
          filterdiff -p1 -i 'hermes_cli/*' ${p} | patch -p1
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
      # rev = null: no HERMES_REVISION, like spaces' build, so the wrapper
      # does not change with our flake's revision. Upstream reads
      # `inputs.self.rev or null`.
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

  hermesPackage = hermesUpstream.packages.default.overrideAttrs (old: {
    # Patch the bundled simplex plugin in place (evidence in the patch
    # headers). In place, not via extraPlugins: that installs a second
    # adapter beside the bundled one, and the two fight over the platform
    # name. The bundled path is a read-only store symlink; replace it with
    # a writable copy first.
    postInstall = (old.postInstall or "") + ''
      plugins=$out/share/hermes-agent/plugins
      bundled=$(readlink -f "$plugins")
      rm "$plugins"
      cp -r --no-preserve=mode,ownership "$bundled" "$plugins"
      patch -p1 -d "$plugins" < ${./patches/hermes-simplex-accept-by-id.patch}
      patch -p1 -d "$plugins" < ${./patches/hermes-simplex-defer-inbound-files.patch}
      patch -p1 -d "$plugins" < ${./patches/hermes-simplex-relative-file-paths.patch}
    '';
  });

  simplexPackage = inputs.spaces.packages.${system}.simplex-chat;

  # SIMPLEX_WS_URL alone enables the plugin; `environment` entries win.
  # `port` is the root-held public port the agent dials.
  # SIMPLEX_FILES_FOLDER mirrors the simplex daemon's stateDir: the daemon
  # reports received files relative to its --files-folder, and the adapter
  # resolves them against this base (evidence in
  # ./patches/hermes-simplex-relative-file-paths.patch).
  simplexEnv =
    { stateDir, port }:
    lib.optionalAttrs cfg.simplex.enable {
      SIMPLEX_WS_URL = "ws://127.0.0.1:${toString port}";
      SIMPLEX_FILES_FOLDER = "${stateDir}/simplex/files";
    };

  # What an agent process runs with. The units in native.nix and the
  # `hermes` shim in cli.nix both apply it. `home` is the account's home
  # (users.users.<user>.home); this file has no `config`.
  nativeRuntime =
    user: home:
    let
      pythonVenv = import ./python-venv.nix { inherit lib pkgs; };
      stateDir = hlib.stateVaultState user;
      repos = configReposOf user;
    in
    {
      inherit stateDir;
      env = {
        # The account home, not the exchange dir: hermes-desktop's SSH
        # connection writes its session token under the SSH login home,
        # and `hermes serve` accepts it only under Path.home().
        HOME = home;
        HERMES_HOME = "${stateDir}/.hermes";
        # No HERMES_MANAGED: it locks every setting (hermes_cli/config.py,
        # is_managed). native.nix locks only the Nix keys, through
        # HERMES_MANAGED_DIR.

        # Skills read this to tell a sandboxed agent from a native one.
        HERMES_SANDBOX = "none";
        # The nix-built interpreter loads pip-installed manylinux extension
        # modules. Their NEEDED libs resolve through LD_LIBRARY_PATH.
        LD_LIBRARY_PATH = pythonVenv.wheelLibraryPath;
      };
      # venv root first, so python and pip resolve to the writable
      # interpreter. systemd appends /bin to every `path` entry, so this
      # is the venv ROOT, not its bin dir. Callers append
      # config.nix.package when the user has config repos.
      path = [
        "${stateDir}/.venv"
        hermesPackage
        pkgs.bash
        pkgs.coreutils
        pkgs.git
      ]
      ++ basePackages
      ++ cfg.extraPackages;
      hasConfigRepos = repos.dirs != [ ];
    };

  # The config repos this user's agent edits (options.nix, configReposFor):
  # the explicit nixosConfigDir grant plus every apply repo inside this
  # user's home.
  configReposOf =
    user:
    cfg.configRepos.${user} or {
      dirs = [ ];
      apply = { };
      primary = null;
    };

  # The agent edits the repo in place and asks the host to check and
  # apply it through the spaces gateway (spaces packages/integration-nixos).
  # NIXOS_CONFIG_HOSTNAME names the `<repo>/<machine>` target of this host.
  configRepoEnv =
    user:
    let
      repos = configReposOf user;
    in
    lib.optionalAttrs (repos.dirs != [ ]) {
      NIXOS_CONFIG_DIR = repos.primary;
      NIXOS_CONFIG_HOSTNAME = hostName;
    }
    // lib.optionalAttrs (repos.apply != { }) {
      # repo name -> directory, for every repo this agent may also check
      # and apply. spaces skills/nixos-config/SKILL.md reads it.
      NIXOS_CONFIG_REPOS = builtins.toJSON repos.apply;
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
  # imports .env into its process env. Every subprocess inherits it. A
  # persisted PYTHONPATH shadows the venv with the gateway's sealed cp312
  # venv. That causes wrong-ABI imports. A sudo-wielding agent can re-add
  # these keys. So drop them before every start.
  #
  # Then rewrite the credential-managed secret block. hermes loads .env
  # with override=True. That beats the process env. CLI sessions read
  # .env directly. So credentials must land here. Strip-then-append keeps
  # rotated or removed keys from going stale. The markers keep spaces'
  # names, so a block written under the spaces module is replaced, not
  # duplicated.
  envRewriteScript = stateDir: ''
    env_file=${stateDir}/.hermes/.env
    touch "$env_file"
    ${pkgs.gnused}/bin/sed -i -E \
      '/^(export[[:space:]]+)?(PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|NIX_PYTHONPATH)=/d' \
      "$env_file"
    ${pkgs.gnused}/bin/sed -i \
      '/^# BEGIN hermes-microvm credentials$/,/^# END hermes-microvm credentials$/d' \
      "$env_file"
    if [ -n "''${CREDENTIALS_DIRECTORY:-}" ]; then
      {
        echo "# BEGIN hermes-microvm credentials"
        for f in "$CREDENTIALS_DIRECTORY"/*; do
          [ -f "$f" ] || continue
          printf '%s=%s\n' "$(basename "$f")" "$(cat "$f")"
        done
        echo "# END hermes-microvm credentials"
      } >> "$env_file"
    fi
  '';
}
