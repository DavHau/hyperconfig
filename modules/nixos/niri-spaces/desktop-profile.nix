# The desktop-profile wiring the spaces `spaces` module used to do around the
# niri + noctalia desktop, recreated locally.
#
# Provenance: modules/nixos/spaces.nix at d413f1f53bafc446b81e1cf9ef4afcf41391ddb1
# (0434912e^, "niri/noctalia: use cosmic for easier user experience", 2026-09-01)
# in the `spaces` flake input, plus the two command wrappers that commit dropped
# from modules/nixos/spaces-commands.nix. The locked spaces rev now defaults the
# desktop profile onto COSMIC (`services.spaces.cosmic.enable = mkDefault true`);
# this module overrides that back to niri. Only niri itself is vendored
# (./niri.nix). The bar is our own noctalia v5 module (../noctalia); spaces'
# nixosModules.noctalia is v4-only.
{ config, lib, pkgs, inputs, ... }:
let
  # The locked spaces repo's own wrapper builder, so the replacements below are
  # built exactly like every other spaces command wrapper (failure toast etc.).
  mkCommand = import (inputs.spaces + /lib/spaces-command.nix) pkgs;
in
{
  imports = [
    ./niri.nix
    ../noctalia
    ../noctalia/layout.nix
  ];

  # The locked spaces bundle turns COSMIC on for the desktop profile. These
  # hosts stay on niri + noctalia, so it stays off (and the cosmic-greeter
  # default it sets is killed by ./../greetd.nix).
  services.spaces.cosmic.enable = false;

  # What spaces.nix did under `config.spaces.profile == "desktop"`.
  services.spaces.niri.enable = lib.mkDefault true;
  services.noctalia.enable = lib.mkDefault true;

  services.greetd = {
    enable = lib.mkDefault true;
    settings.default_session = {
      command = lib.mkDefault "${config.programs.niri.package}/bin/niri-session";
      user = lib.mkDefault "alice";
    };
  };

  # The two wrappers the cosmic migration removed from spaces-commands.nix:
  #   - bar-reload was dropped outright (cosmic has no bar to restart);
  #   - screen-lock's text was rewritten to `loginctl lock-session` (cosmic-idle
  #     runs the COSMIC locker). Under niri the deployed behaviour is swaylock,
  #     so shadow the locked loginctl wrapper with a byte-identical copy of the
  #     old swaylock one. Same package name, so the two collide in the system
  #     env; hiPrio resolves the collision deterministically in our favour, and
  #     the niri binds spawn these by bare name off PATH.
  # Gated like the old module (`niri || noctalia`); services.spaces.commands
  # itself comes from the locked bundle.
  environment.systemPackages =
    lib.mkIf (config.services.spaces.niri.enable or false || config.services.noctalia.enable or false) [
      (lib.hiPrio (mkCommand {
        name = "spaces-bar-reload";
        label = "reload the status bar";
        text = "systemctl --user restart noctalia-shell.service";
      }))
      (lib.hiPrio (mkCommand {
        name = "spaces-screen-lock";
        label = "lock the screen";
        text = "swaylock";
      }))
    ];
}
