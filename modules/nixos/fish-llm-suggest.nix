# Live, as-you-type LLM autosuggestions in fish, from the p0 endpoint
# (https://inference.p0.contact/v1, model qwen; token via `p0-api-key`,
# ./inference-api-key.nix).
#
# fish has no hook for foreign autosuggestions, so fish is patched
# (pkgs/fish-llm-suggest/fish-autosuggestion-extra.patch):
# - `fish_autosuggestion_extra`: whole-line candidates, offered as ghost
#   text after history and before completions; changing it re-renders.
# - `fish_autosuggestion_socket`: the autosuggestion thread sends each
#   command line there, tagged covered (history/candidate) or not.
# The shell runs under a pty proxy (pkgs/fish-llm-suggest) that records the
# last commands with output tails (fish's OSC 133 marks), debounces,
# keeps one request in flight, caches, and answers via SIGUSR1
# (../home-manager/fish-llm-suggest.fish).
{ config, lib, pkgs, ... }:
let
  cfg = config.hyper.fishLlmSuggest;
  fish = pkgs.fish.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../../pkgs/fish-llm-suggest/fish-autosuggestion-extra.patch ];
  });
in
{
  options.hyper.fishLlmSuggest.users = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Users (with a home-manager config) whose interactive fish gets LLM autosuggestions.";
  };

  config = lib.mkIf (cfg.users != [ ]) {
    # The patch is inert unless the variables are set, so all users may share it.
    programs.fish.package = fish;
    home-manager.users = lib.genAttrs cfg.users (_: {
      imports = [ ../home-manager/fish-llm-suggest.nix ];
      programs.fish.package = fish;
    });
  };
}
