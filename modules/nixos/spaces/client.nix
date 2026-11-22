/*
  Dave's way into every space-like container, on his desktops
  (../dave-desktop): the named spaces (./default.nix) on each of their
  machines, infra-space (../infra-space) on each member and the container
  slots of ./slots.nix (hyperhermes' container-slots), one entry per
  copy of ./public.nix, all named alike:

    - the guest's host key pinned for `[address]:port` (so it never stands
      in for the host's own sshd on port 22), from its public clan var;
    - the ssh alias `<space>-<machine>` (/etc/ssh/ssh_config: address,
      port, user); `ssh infra-space-som` works as from inside infra-space;
    - a launcher "<space> (<machine>)", ghostty with an ssh login through
      the alias, attached to tmux session `main` (a closed window leaves
      the shell and any afk session running; not for the slots, which
      may have no tmux);
    - with `hyper.spacesClient.herdrUser` set, a saved herdr SSH machine
      labelled "<space> (<machine>)", target the alias, its `session`,
      in that user's herdr (herdr-space-machines.py, run by the user's
      nixos-activation.service, i.e. at every switch and login). Open herdr
      clients pick it up within a second. herdr starts the guest's herdr
      server itself on first attach (the guests have the same herdr,
      ./guest.nix, ../infra-space/guest.nix); ssh authenticates with
      Dave's agent keys, which the guests authorize.

  Only public values: nothing here evaluates the containers' machines'
  configs. A space whose host key is not generated yet is skipped
  (./public.nix). A managed herdr entry Dave removes comes back at the
  next switch: remove the space from the registry instead.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.spacesClient;
  inherit (cfg) spaces;
  # (OpenSSH rejects a bracketed v6 address in an ssh:// target, hence an
  # alias for herdr's targets; the launchers use it too.)
  label = s: "${s.space} (${s.machine})";

  entry =
    alias: s:
    pkgs.makeDesktopItem {
      name = alias;
      desktopName = label s;
      comment = "Shell as ${s.user} in ${s.space} on ${s.machine}";
      exec = "ghostty -e ssh -t ${alias} tmux new -A -s main";
      categories = [
        "Network"
        "System"
      ];
    };

  machinesFile = pkgs.writeText "herdr-space-machines.json" (
    builtins.toJSON (
      lib.mapAttrsToList (alias: s: {
        id = s.herdrId;
        label = label s;
        target = alias;
        inherit (s) session;
      }) spaces
    )
  );
  herdrMachines = pkgs.writers.writePython3 "herdr-space-machines" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./herdr-space-machines.py);
in
{
  options.hyper.spacesClient = {
    herdrUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "grmpf";
      description = "User whose herdr gets every space as a saved SSH machine.";
    };
    spaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              space = lib.mkOption { type = lib.types.str; };
              machine = lib.mkOption { type = lib.types.str; };
              user = lib.mkOption { type = lib.types.str; };
              address = lib.mkOption { type = lib.types.str; };
              sshPort = lib.mkOption { type = lib.types.port; };
              hostKey = lib.mkOption { type = lib.types.str; };
              session = lib.mkOption {
                type = lib.types.str;
                default = "default";
                description = "herdr session of the herdr machine.";
              };
              launcher = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Add the ghostty launcher (needs tmux in the guest).";
              };
              herdrId = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Name the herdr entry's fixed id derives from (./public.nix).";
              };
            };
          }
        )
      );
      default = import ./public.nix {
        inherit lib;
        inherit (inputs.clan-core) clanLib;
        flake = config.clan.core.settings.directory;
      };
      defaultText = lib.literalMD "every copy of every space of ./registry.nix whose host key is generated, and infra-space on every member (./public.nix)";
      description = "The containers to reach from here, by ssh alias `<space>-<machine>`.";
    };
  };

  config = {
    environment.systemPackages = lib.mapAttrsToList entry (lib.filterAttrs (_: s: s.launcher) spaces);

    programs.ssh.knownHosts = lib.mapAttrs (alias: s: {
      hostNames = [ "[${s.address}]:${toString s.sshPort}" ];
      publicKey = s.hostKey;
    }) spaces;

    programs.ssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList (alias: s: ''
        Host ${alias}
          HostName ${s.address}
          Port ${toString s.sshPort}
          User ${s.user}
      '') spaces
    );

    system.userActivationScripts.herdr-space-machines = lib.mkIf (cfg.herdrUser != null) {
      text = ''
        if [ "$(${pkgs.coreutils}/bin/id -un)" = ${lib.escapeShellArg cfg.herdrUser} ]; then
          SPACES_FILE=${machinesFile} ${herdrMachines} || echo "herdr-space-machines failed" >&2
        fi
      '';
    };
  };
}
