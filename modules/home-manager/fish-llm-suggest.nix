# Shell half of live LLM autosuggestions; needs the patched fish that
# modules/nixos/fish-llm-suggest.nix installs (it imports this module).
{ lib, pkgs, ... }:
let
  proxy = pkgs.callPackage ../../pkgs/fish-llm-suggest { };
in
{
  # 00-: re-exec under the proxy before the other snippets run twice.
  xdg.configFile."fish/conf.d/00-fish-llm-suggest.fish".source =
    pkgs.replaceVars ./fish-llm-suggest.fish { proxy = lib.getExe proxy; };
}
