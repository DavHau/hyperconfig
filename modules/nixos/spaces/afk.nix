/*
  afk in a space's guest, for Dave's interactive sessions: the guest
  module for a space whose credentials sit in `secretsDir`. Shared by
  infra-space (../infra-space/afk.nix) and the named spaces
  (./default.nix). The same wrapper as on the desktops (../afk.nix), minus
  what a space must not have:

    - No personal skills: those (mail, signal, ...) reach the desktops
      through the spaces module's ~/.agents/skills, which the guest does
      not import, nor ../dave.nix.
    - No web_search, URL fetching or browser: pinned off in afk's settings
      (hyper.afk.pinnedSettings, ../afk.nix has why that is an overlay and
      not afk's distro layer), so nothing the agent reads comes straight
      off the web.
    - The p0 and TeamClaude keys are the credentials `p0-api-key` and
      `teamclaude-api-key` (passed in by the host, from the same clan
      vars the desktops use); the same-named commands models.yml runs read
      them from `secretsDir`.

  jobs-hub and the herdr bridge come along with ../afk.nix: both are TUI
  extensions, the latter inert outside a herdr pane.

  tmux keeps shells (and afk sessions) alive across ssh disconnects;
  Dave's launchers attach to session `main`.
*/
secretsDir: {
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
