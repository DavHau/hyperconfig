# Vendored from the `spaces` flake input (github:generational-infrastructure/spaces-os).
# Provenance: modules/nixos/niri.nix at d413f1f53bafc446b81e1cf9ef4afcf41391ddb1
# (0434912e^, "niri/noctalia: use cosmic for easier user experience", 2026-09-01).
# Upstream deleted the niri desktop module in favour of COSMIC; hyperconfig vendors
# it verbatim (minus the ./spaces-commands.nix import, which the locked spaces
# bundle already provides, plus the wrapperNames note below) so the niri desktop
# stack keeps evaluating byte-equivalently.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.spaces.niri;
  cmds = config.services.spaces.commands;

  # Vendored sibling (was ../keybinds.nix in the spaces tree).
  kb = import ./keybinds.nix { inherit lib; };

  niriChord =
    chord:
    lib.concatMapStringsSep "+" (tok: if tok == "SMod" then "Mod" else tok) (lib.splitString "+" chord);

  # `++ [ "spaces-bar-reload" ]`: the lock-screen-less bar-reload wrapper left
  # spaces' spaces-commands.nix with the cosmic migration; desktop-profile.nix
  # (this directory) puts a byte-identical replacement on PATH, so the spawn
  # check must accept it.
  wrapperNames = lib.mapAttrsToList (_attr: c: c.name) cmds ++ [ "spaces-bar-reload" ];
  checkedSpawn =
    spawn:
    if lib.hasPrefix "spaces-" spawn && !(lib.elem spawn wrapperNames) then
      throw "niri.nix: keybind spawn '${spawn}' is not a spaces-commands wrapper (known: ${lib.concatStringsSep ", " wrapperNames})"
    else
      spawn;

  modelBinds = map (bind: [
    (niriChord bind.chord)
    {
      spawn = [ (checkedSpawn bind.spawn) ];
      inherit (bind) title;
    }
  ]) kb.niriSpawnBinds;

  userBinds = lib.mapAttrsToList (chord: bind: [
    (niriChord chord)
    (lib.mapNullable (b: {
      spawn = if b.spawn == null then null else map checkedSpawn b.spawn;
      inherit (b) action title;
    }) bind)
  ]) cfg.binds;

  xkb = config.services.xserver.xkb;

  niriConfig =
    pkgs.runCommand "niri-config.kdl"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.libxkbcommon
          pkgs.niri
        ];
        binds = builtins.toJSON (modelBinds ++ userBinds);
        passAsFile = [ "binds" ];
      }
      ''
            cp ${pkgs.niri.src}/resources/default-config.kdl scaffold.kdl
            chmod +w scaffold.kdl
            grep -q 'spawn-at-startup "waybar"' scaffold.kdl  # fail loudly if upstream renamed it
            sed -i '/spawn-at-startup "waybar"/d' scaffold.kdl
            sed -i '/^input {$/a\    mod-key "${cfg.modKey}"' scaffold.kdl
            grep -q '^    touchpad {$' scaffold.kdl  # fail loudly if upstream renamed it
            sed -i '/^    touchpad {$/,/^    }$/d' scaffold.kdl
            sed -i '/^    mouse {$/i\
            touchpad {\
                tap\
                dwt\
                dwtp\
                drag true\
                drag-lock\
                natural-scroll\
                click-method "clickfinger"\
                tap-button-map "left-right-middle"\
            }\

        ' scaffold.kdl

            # Binds are NOT sed-injected. The renderer merges the model over
            # upstream's scaffold and translates every chord onto the configured
            # layout. niri matches a bind against the level-1 keysym of the
            # active layout, so an untranslated US chord is dead on de: the
            # keysym it names is nowhere at level 1. modules/niri-render-binds.py
            # carries the full case.
            python3 ${./niri-render-binds.py} \
              --kdl scaffold.kdl \
              --out rendered.kdl \
              --binds "$(cat "$bindsPath")" \
              --layout ${lib.escapeShellArg xkb.layout} \
              --model ${lib.escapeShellArg xkb.model} \
              --variant ${lib.escapeShellArg xkb.variant} \
              --options ${lib.escapeShellArg xkb.options}

            # niri parses its own config here, so a bad services.spaces.niri.binds
            # entry or a keysym the layout cannot express fails the BUILD. The
            # alternative is a compositor that refuses to start after a deploy.
            HOME="$PWD" niri validate -c rendered.kdl
            mv rendered.kdl $out
      '';
in
{
  # The spaces bundle (nixosModules.spaces -> ... -> spaces-commands.nix) already
  # publishes services.spaces.commands, so the upstream `imports = [ ./spaces-commands.nix ];`
  # is dropped: re-importing would double-define the readOnly option.
  options.services.spaces.niri.enable = lib.mkEnableOption ''
    the niri scrollable-tiling Wayland compositor and its supporting
    services (polkit, gnome-keyring, swaylock PAM, terminal/launcher/lock
    tools, and the deterministic /etc/niri/config.kdl)'';

  options.services.spaces.niri.modKey = lib.mkOption {
    type = lib.types.enum [
      "Super"
      "Alt"
    ];
    default = "Super";
    description = ''
      Modifier key used by niri's keybinds. Defaults to "Super" for
      bare-metal installs. VM-based test runners override this to
      "Alt" so the guest does not fight the host compositor's Super
      grab.
    '';
  };

  options.services.spaces.niri.binds = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.nullOr (
        lib.types.submodule {
          options = {
            spawn = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              example = [ "alacritty" ];
              description = ''
                Program and arguments to exec. A `spaces-*` name must be a real
                wrapper from `modules/nixos/spaces-commands.nix`, or evaluation
                fails. Mutually exclusive with `action`.
              '';
            };
            action = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = ''set-column-width "-10%"'';
              description = ''
                A niri action, written as it appears in config.kdl including any
                arguments. Mutually exclusive with `spawn`.
              '';
            };
            title = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Label shown in niri's hotkey overlay (Mod+Shift+/).";
            };
          };
        }
      )
    );
    description = ''
      Keybinds in /etc/niri/config.kdl, keyed by chord. An entry adds or
      replaces one bind. `null` drops an upstream bind.
    '';
    example = lib.literalExpression ''
      {
        "Mod+Shift+B" = { spawn = [ "spaces-bar-reload" ]; title = "Reload bar"; };
        "Mod+Escape" = null;  # drop an upstream bind
      }
    '';
  };

  config = lib.mkIf cfg.enable {
    programs.niri.enable = true;

    security.polkit.enable = true; # required by swaylock
    services.gnome.gnome-keyring.enable = true; # Secret Service backend
    security.pam.services.swaylock = { };

    environment.systemPackages = with pkgs; [
      alacritty # Super+T
      fuzzel # Super+D
      swaylock # Super+Alt+L
      swayidle
      xwayland-satellite
    ];

    environment.etc."niri/config.kdl".source = niriConfig;

    systemd.user.services.niri = {
      # Stable /etc symlink, not the store path. So niri live-reloads config
      # on deploy. canonicalize() changes when a deploy re-points the symlink.
      # An explicit NIRI_CONFIG stops niri from auto-creating
      # ~/.config/niri/config.kdl.
      environment.NIRI_CONFIG = "/etc/niri/config.kdl";
      # The NixOS default injects a stripped PATH=. That PATH hides
      # /run/current-system/sw/bin from niri's bare-name `spawn` actions.
      enableDefaultPath = false;
      restartIfChanged = false; # don't kill the desktop on deploy
    };
  };
}
