/*
  afk in the infra-space container, for Dave's interactive sessions as
  `infra` (hermes never starts it). The same wrapper as on the desktops
  (../afk.nix), minus what the space must not have:

    - No personal skills: those (mail, signal, ...) reach the desktops
      through the spaces module's ~/.agents/skills, which the guest does
      not import, nor ../dave.nix.
    - No web_search, URL fetching or browser: pinned off in afk's settings
      (hyper.afk.pinnedSettings, ../afk.nix has why that is an overlay and
      not afk's distro layer), so nothing the agent reads comes straight
      off the web.
    - The p0 and TeamClaude keys come in as credentials (from the same
      clan vars the desktops use, both shared and deployed on som and amy
      through ../dave.nix); `p0-api-key` and `teamclaude-api-key`, which
      models.yml runs, read them from /run/infra-space/secrets.

  jobs-hub and the herdr bridge come along with ../afk.nix: both are TUI
  extensions, the latter inert outside a herdr pane.

  tmux keeps shells (and afk sessions) alive across ssh disconnects; Dave's
  launcher (./launchers.nix) attaches to session `main`.
*/
{ config, lib, ... }:
let
  cfg = config.hyper.infraSpace;
  vars = config.clan.core.vars.generators;
  secretsDir = "/run/infra-space/secrets";
in
{
  config = lib.mkIf cfg.enable {
    hyper.infraSpace.credentials = {
      p0-api-key = vars.inference-api-key.files.token.path;
      teamclaude-api-key = vars.teamclaude-api-key.files.key.path;
    };

    hyper.infraSpace.guestModules = [
      {
        imports = [
          ../afk.nix
          ../inference-api-key.nix
          ../teamclaude-api-key.nix
        ];
        hyper.inferenceApiKey.tokenFile = "${secretsDir}/p0-api-key";
        hyper.teamclaudeApiKey.keyFile = "${secretsDir}/teamclaude-api-key";
        hyper.afk.pinnedSettings = {
          web_search.enabled = false;
          # also URL reads through the read tool
          fetch.enabled = false;
          browser.enabled = false;
        };
        programs.tmux.enable = true;
      }
    ];
  };
}
