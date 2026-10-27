{config, pkgs, ...}: {
  # Follow programs.fish.package, so a patched fish (fish-llm-suggest.nix) is
  # also the login shell instead of a second, stock fish in the system path.
  users.defaultUserShell = config.programs.fish.package;
  programs.fish.enable = true;
}
