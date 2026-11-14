/*
  afk in the infra-space container, for Dave's interactive sessions as
  `infra` (hermes never starts it): the guest module every space shares
  (../spaces/afk.nix has what it carries and leaves out), with the
  credentials in /run/infra-space/secrets. The p0, TeamClaude and
  OpenRouter keys come from the same clan vars the desktops use, all
  shared and deployed on som and amy through ../dave.nix; ./default.nix passes them in. Dave's
  launcher (./launchers.nix) attaches to tmux session `main`.
*/
{ config, lib, ... }:
let
  cfg = config.hyper.infraSpace;
  secretsDir = "/run/infra-space/secrets";
in
{
  config = lib.mkIf cfg.enable {
    hyper.infraSpace.guestModules = [ (import ../spaces/afk.nix secretsDir) ];
  };
}
