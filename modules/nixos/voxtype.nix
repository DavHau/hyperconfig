# Voice-to-text via voxtype (push-to-talk / toggle mode)
# Uses compositor keybindings (niri) with toggle mode.
# Keybinding: Mod+Space  (defined in niri.nix)
{ inputs, ... }:
{
  home-manager.sharedModules = [
    inputs.voxtype.homeManagerModules.default
    {
      programs.voxtype = {
        enable = true;
        package = inputs.voxtype.packages.x86_64-linux.vulkan;
        model.name = "base.en";
        service.enable = true;
        settings = {
          hotkey.enabled = false; # compositor keybindings instead
          whisper.language = "en";
          output = {
            mode = "type";
            fallback_to_clipboard = true;
          };
        };
      };
    }
  ];
}
