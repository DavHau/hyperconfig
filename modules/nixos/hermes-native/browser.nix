# Hermes' local browser on the agents: nixpkgs Chromium, headless, as the
# agent's own uid.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-native;
in
{
  config = lib.mkIf cfg.enable {
    services.hermes-native = {
      # Every browser path (built-in browser_* tools, browser_exec's
      # Chromium) starts with a check that looks only at this variable,
      # PATH and Playwright's cache (tools/browser_tool_install.py,
      # _chromium_installed). The unit PATH has no Chromium, and the
      # Chrome for Testing that `agent-browser install` downloads is
      # neither found by that check nor runnable on NixOS. agent-browser
      # launches what the variable names.
      environment.AGENT_BROWSER_EXECUTABLE_PATH = lib.mkDefault "${pkgs.chromium}/bin/chromium";

      # Real-profile mode copies a desktop Chromium profile, found
      # through xdg-settings. No agent account has either, so the mode
      # fails every browser call closed.
      settings.browser.use_real_profile = lib.mkDefault false;
    };
  };
}
