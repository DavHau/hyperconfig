# Noctalia v5 (native C++ shell, pkgs.noctalia) as a per-user systemd service.
#
# Replaces spaces' v4 module (inputs.spaces.nixosModules.noctalia: Quickshell,
# JSON settings deep-merged by jq, QML plugins), which v4's end of life and
# Qt 6.12 broke (Qt's new QtQuick `Color` singleton shadows v4's theme
# singleton: black icons, `smartAlpha is not a function`).
#
# Config: v5 merges every ~/.config/noctalia/*.toml alphabetically, then the
# GUI's ~/.local/state/noctalia/settings.toml on top. `settings` renders to
# one TOML file that ExecStartPre links in as 00-nixos.toml: the lowest-ranked
# user file, so hand-written files and GUI changes still win. Lists merge by
# concatenation (mkBefore/mkAfter order them), which is how other modules add
# bar widgets.
#
# Plugins: every `plugins.<name>` dir (plugin.toml + .luau) is copied into one
# store dir, served as a read-only `path` plugin source and enabled as
# `hyperconfig/<name>`.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.noctalia;
  toml = pkgs.formats.toml { };

  pluginDir = pkgs.runCommand "noctalia-plugins" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: src: ''
        cp -r ${src} $out/${name}
      '') cfg.plugins
    )
  );

  pluginSettings = lib.optionalAttrs (cfg.plugins != { }) {
    plugins = {
      source = [
        {
          name = "nixos";
          kind = "path";
          location = "${pluginDir}";
          enabled = true;
        }
      ];
      enabled = map (name: "hyperconfig/${name}") (lib.attrNames cfg.plugins);
    };
  };

  configFile = toml.generate "noctalia-nixos.toml" (lib.recursiveUpdate cfg.settings pluginSettings);

  # Fails the build on config errors (bad keys are only warnings).
  checkedConfig = pkgs.runCommand "noctalia-nixos-checked.toml" { } ''
    export HOME=$TMPDIR
    ${lib.getExe cfg.package} config validate ${configFile}
    cp ${configFile} $out
  '';

  linkConfig = pkgs.writeShellApplication {
    name = "noctalia-link-config";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      cfgDir="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
      mkdir -p "$cfgDir"
      ln -sfn ${checkedConfig} "$cfgDir/00-nixos.toml"
    '';
  };
in
{
  options.services.noctalia = {
    enable = lib.mkEnableOption "the noctalia (v5) Wayland shell user service";

    package = lib.mkPackageOption pkgs "noctalia" { };

    settings = lib.mkOption {
      inherit (toml) type;
      default = { };
      description = ''
        Noctalia config, rendered to ~/.config/noctalia/00-nixos.toml.
        See https://docs.noctalia.dev/noctalia/configuration/.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Plugin directories by name. Each is enabled as `hyperconfig/<name>`,
        so its plugin.toml id must be exactly that.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.libnotify
      pkgs.wl-clipboard
      pkgs.xdg-utils
    ];

    # Battery widget reads UPower over D-Bus.
    services.upower.enable = true;

    # Unit name kept from v4: spaces-bar-reload and the niri bind restart it.
    systemd.user.services.noctalia-shell = {
      description = "Noctalia Wayland desktop shell";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [
        cfg.package
        linkConfig
      ];
      serviceConfig = {
        ExecStartPre = "${linkConfig}/bin/noctalia-link-config";
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        Slice = "session.slice";
        # Widgets and plugins spawn helpers by bare name.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
