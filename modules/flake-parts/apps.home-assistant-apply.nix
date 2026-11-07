# `nix run .#home-assistant-apply -- [--dry-run] [--skip-token] [playa|casa ...]`:
# converges Roman's Home Assistant instances to ../../home-assistant/hosts.nix.
# Run from the repo root: minted tokens go into som's clan vars there.
{ self, lib, ... }:
let
  hosts = import ../../home-assistant/hosts.nix { inherit self lib; };
in
{
  perSystem = { pkgs, ... }:
    let
      program = pkgs.writeShellApplication {
        name = "home-assistant-apply";
        # clan comes from the devshell (it is not a nixpkgs package).
        runtimeInputs = [ pkgs.python3 pkgs.openssh ];
        text = ''
          exec python3 ${../../home-assistant/apply.py} \
            --state ${pkgs.writeText "home-assistant-hosts.json" (builtins.toJSON hosts)} \
            --remote ${../../home-assistant/remote.py} "$@"
        '';
      };
    in
    {
      apps.home-assistant-apply = {
        type = "app";
        program = lib.getExe program;
      };
    };
}
