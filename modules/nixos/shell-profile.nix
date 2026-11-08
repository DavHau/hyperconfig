# Dave's default shell profile, for every place he gets a shell: his desktops
# (./dave.nix) and the infra-space containers (./infra-space/guest.nix).
#
# fish as the login shell (bash execs fish for interactive sessions), the
# shared aliases, zoxide, direnv, tmux with mouse scrolling, and the common
# CLI tools. System-level on purpose, so it works for any user without
# home-manager. Personal extras that call out to services (fish-ai) stay in
# ../home-manager.
{
  imports = [
    ./fish.nix
    ./common-tools.nix
    ./shell-aliases.nix
  ];

  programs.zoxide.enable = true;
}
