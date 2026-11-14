/*
  Dave's desktop apps, the same set on every desktop that imports
  ../dave.nix (amy, vit, som):

    - ./shared-app.nix: the shared "Hermes Desktop" app (hyperhermes'
      desktop module) for som's trusted agents, plus their "Hermes TUI"
      entries;
    - ./isolated-apps.nix: "Hermes (voice)" and "Hermes (infra-space)",
      each the hermes app in a confined container of its own here
      (../space-gui on the desktop user's session);
    - the shells: "infra-space (<member>)" (../infra-space/launchers.nix)
      and "<space> space" plus herdr machines for the named spaces
      (../spaces/client.nix).

  Which agent gets which kind of app: ./apps.nix.

  `hyper.daveDesktop.user` is the desktop user whose session shows the
  container apps (space-gui's host user) and whose herdr gets the spaces:
  grmpf on amy, dave elsewhere.
*/
{ config, lib, ... }:
let
  cfg = config.hyper.daveDesktop;
in
{
  imports = [
    ./shared-app.nix
    ./isolated-apps.nix
    ../infra-space/launchers.nix
    ../spaces/client.nix
  ];

  options.hyper.daveDesktop.user = lib.mkOption {
    type = lib.types.str;
    default = "dave";
    example = "grmpf";
    description = "Dave's desktop user here: the session the container apps show on, and the herdr that gets the spaces.";
  };

  config = {
    hyper.spaceGui.hostUser = cfg.user;
    hyper.spacesClient.herdrUser = cfg.user;
  };
}
