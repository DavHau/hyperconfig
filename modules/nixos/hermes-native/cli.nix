# The `hermes` CLI/TUI for an agent's owner, and `hermes-simplex-qr`.
# Vendored from spaces 6d744780 modules/nixos/hermes/cli.nix (native
# arms only). The desktop app launcher stays in spaces.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.services.hermes-native;
  hlib = import ./lib.nix { inherit lib; };
  ac = import ./agent-config.nix {
    inherit
      lib
      pkgs
      inputs
      hlib
      cfg
      ;
    inherit (config.networking) hostName;
  };

  # Resolves the caller itself, so one user never reads another's address.
  simplexQr = pkgs.writeShellApplication {
    name = "hermes-simplex-qr";
    runtimeInputs = [
      pkgs.qrencode
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      u="$(id -un)"
      case "$u" in
      ${qrUserCaseArms}
      *)
        echo "hermes-simplex-qr: no native hermes agent configured for user $u" >&2
        exit 1
        ;;
      esac
      ${builtins.readFile ./simplex-qr.sh}
    '';
  };

  # AGENT_UNIT names the unit whose absence explains a missing address.
  qrUserCaseArms = lib.concatStrings (
    lib.mapAttrsToList (user: _: ''
      ${user})
        ADDRESS_FILE=${hlib.simplexAddressFile user}
        AGENT_UNIT=hermes-simplex-address-${user}
        ;;
    '') cfg.enabledUsers
  );

  # The CLI runs the agent package directly, with the environment and
  # PATH the gateway unit has (agent-config.nix, nativeRuntime): same
  # HERMES_HOME, same venv first on PATH, same skill CLIs, same HOME, and
  # the same per-setting locks (HERMES_MANAGED_DIR). HOME is the account
  # home, so the shim enters the workspace by path. LD_LIBRARY_PATH
  # prepends rather than replaces the caller's.
  userCaseArms = lib.concatStrings (
    lib.mapAttrsToList (
      user: _:
      let
        rt = ac.nativeRuntime user config.users.users.${user}.home;
        path = rt.path ++ lib.optional rt.hasConfigRepos config.nix.package;
        env = lib.filterAttrs (n: _: n != "LD_LIBRARY_PATH") rt.env // {
          HERMES_MANAGED_DIR = "${cfg.managedDirs.${user}}";
        };
      in
      ''
        ${user})
          ${lib.concatStringsSep "\n    " (
            lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}") env
          )}
          export PATH=${lib.escapeShellArg (lib.makeBinPath path)}:"$PATH"
          export LD_LIBRARY_PATH=${lib.escapeShellArg rt.env.LD_LIBRARY_PATH}"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          cd ${lib.escapeShellArg (hlib.workspace user)}
          ;;
      ''
    ) cfg.enabledUsers
  );

  hermesShim = pkgs.writeShellScriptBin "hermes" ''
    u="$(${pkgs.coreutils}/bin/id -un)"
    case "$u" in
    ${userCaseArms}
    *)
      echo "hermes: no native hermes agent configured for user $u" >&2
      exit 1
      ;;
    esac
    ${pkgs.systemd}/bin/systemctl is-active --quiet "hermes-agent-$u.service" || {
      echo "hermes: hermes-agent-$u is not running (systemctl status hermes-agent-$u)" >&2
      exit 1
    }
    exec ${ac.hermesPackage}/bin/hermes "$@"
  '';
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ hermesShim ] ++ lib.optional cfg.simplex.enable simplexQr;
  };
}
