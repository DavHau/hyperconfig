/*
  Dave's way into infra-space, on his desktops (../dave.nix): one launcher
  entry per member, "infra-space (<member>)", opening ghostty with an ssh
  login as `infra` into that member's container (Dave's admin keys are
  authorized there, ./default.nix), attached to the tmux session `main` so
  a closed window leaves the shell and any afk session running.

  Addresses and pinned host keys are the members' public clan vars
  (./public-members.nix); nothing here evaluates another machine's
  config. The known_hosts entry is `[address]:port`, so the container's
  key never stands in for the member host's own sshd on port 22.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  members = import ./public-members.nix {
    inherit lib;
    inherit (inputs.clan-core) clanLib;
    flake = config.clan.core.settings.directory;
  };

  entry =
    member: m:
    pkgs.makeDesktopItem {
      name = "infra-space-${member}";
      desktopName = "infra-space (${member})";
      comment = "Shell as infra in ${member}'s infra-space container";
      exec = "ghostty -e ssh -t -p ${toString m.sshPort} infra@${m.address} tmux new -A -s main";
      categories = [
        "Network"
        "System"
      ];
    };
in
{
  environment.systemPackages = lib.mapAttrsToList entry members;

  programs.ssh.knownHosts = lib.mapAttrs' (
    member: m:
    lib.nameValuePair "infra-space-${member}" {
      hostNames = [ "[${m.address}]:${toString m.sshPort}" ];
      publicKey = m.hostKey;
    }
  ) members;
}
