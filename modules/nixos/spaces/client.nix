/*
  Dave's way into the named spaces (./default.nix), on the machine that
  imports this (amy): per space of ./public.nix

    - the guest's host key pinned for `[address]:port` (so it never stands
      in for the host's own sshd on port 22), from its public clan var;
    - a launcher "<name> space", ghostty with an ssh login as the space's
      user, attached to tmux session `main` (as ../infra-space/launchers.nix);
    - with `hyper.spacesClient.herdrUser` set, a saved herdr SSH machine labelled
      <name>, target the ssh alias `space-<name>` (/etc/ssh/ssh_config: address,
      port, user), session `default`, in
      that user's herdr (herdr-space-machines.py, run by
      the user's nixos-activation.service, i.e. at every switch and login).
      Open herdr clients pick it up within a second. herdr starts the
      space's herdr server itself on first attach (the guest has the same
      herdr, ./guest.nix); ssh authenticates with Dave's agent keys, which
      the spaces authorize.

  Only public values: nothing here evaluates the spaces' machine's config.
  A space whose host key is not generated yet is skipped (./public.nix).
  A managed herdr entry Dave removes comes back at the next switch:
  remove the space from the registry instead.
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
  # An ssh alias per space: herdr's targets and the launchers use it.
  # (OpenSSH rejects a bracketed v6 address in an ssh:// target.)
  alias = name: "space-${name}";

  entry =
    name: s:
    pkgs.makeDesktopItem {
      name = "space-${name}";
      desktopName = "${name} space";
      comment = "Shell as ${s.user} in the ${name} space (${s.machine})";
      exec = "ghostty -e ssh -t ${alias name} tmux new -A -s main";
      categories = [
        "Network"
        "System"
      ];
    };

  machinesFile = pkgs.writeText "herdr-space-machines.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: s: {
        inherit name;
        label = name;
        target = alias name;
        session = "default";
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
        lib.types.submodule {
          options = {
            machine = lib.mkOption { type = lib.types.str; };
            user = lib.mkOption { type = lib.types.str; };
            address = lib.mkOption { type = lib.types.str; };
            sshPort = lib.mkOption { type = lib.types.port; };
            hostKey = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = import ./public.nix {
        inherit lib;
        inherit (inputs.clan-core) clanLib;
        flake = config.clan.core.settings.directory;
      };
      defaultText = lib.literalMD "every space of ./registry.nix whose host key is generated (./public.nix)";
      description = "The spaces to reach from here.";
    };
  };

  config = {
    environment.systemPackages = lib.mapAttrsToList entry spaces;

    programs.ssh.knownHosts = lib.mapAttrs' (
      name: s:
      lib.nameValuePair "space-${name}" {
        hostNames = [ "[${s.address}]:${toString s.sshPort}" ];
        publicKey = s.hostKey;
      }
    ) spaces;

    programs.ssh.extraConfig = lib.concatStrings (
      lib.mapAttrsToList (name: s: ''
        Host ${alias name}
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
