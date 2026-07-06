# Mod+T terminal that follows the focused window's working directory.
#
# Installs niri-terminal-cwd (see ./niri-terminal-cwd-package.nix) on the
# system PATH so niri can spawn it by bare name. The Mod+T bind that invokes
# it lives in ./niri-monitor-binds.nix, which owns the host-local niri binds
# wrapper config.
#
# Tested by the `niri-terminal-cwd` flake check
# (./niri-terminal-cwd-test.nix).
{ pkgs, ... }:
{
  environment.systemPackages = [
    (import ./niri-terminal-cwd-package.nix { inherit pkgs; })
  ];
}
