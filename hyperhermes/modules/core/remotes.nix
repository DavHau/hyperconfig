# The `remote` CLI of agents with ssh targets
# (services.hyperhermes.agents.<name>.remotes): `remote <target>
# run|put|get|<command>` runs commands and moves files on a container slot
# or host the agent reaches over ssh, without nested quoting (./remote.sh).
#
# A target names an ssh destination the agent can already log in to (its
# own ssh_config entry, key and host key pinning stay with whoever grants
# the login); this module adds no access, only the client. Every target
# gets run (a command's words, or a local script, sent base64-encoded on
# one fixed ssh command line, output capped with the whole of it in a
# local file), put/get (into a per-target scratch dir), and a table of
# target-specific commands (`commands`: a fixed argv prefix, or a script
# kept here and run there by an interpreter). One ssh master connection
# per target, in the agent's runtime dir, persisting 10 minutes. (Also
# the name checks of core's profileSkills, which has no module of its own.)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;

  commandType = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "words"
          "joined"
          "script"
        ];
        default = "words";
        description = ''
          How the caller's arguments reach the target. `words`: `prefix`
          then the arguments, each one word, run there. `joined`: `prefix`
          then ONE word holding the arguments POSIX-quoted and joined (for
          a command that hands a string on, e.g. `ssh <host>` to a forced
          command that splits it with shlex). `script`: `prefix` (an
          interpreter taking `-c`, e.g. [ "python3" ]) runs `script`, the
          arguments as its argv.
        '';
      };
      prefix = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "The command's fixed leading words.";
      };
      script = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "The script for kind `script`.";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Fixed arguments of a `script` before the caller's (e.g. its subcommand).";
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Seconds before it is killed there (the caller's --timeout overrides).";
      };
      usage = lib.mkOption {
        type = lib.types.str;
        default = "[ARG...]";
        description = "The arguments, for `remote <target> help`.";
      };
      help = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "What it does and its argument grammar, for `remote <target> help`.";
      };
    };
  };

  targetType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        host = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The ssh destination (an alias in the agent's ssh_config, or user@host).";
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "One line for `remote list`.";
        };
        cwd = lib.mkOption {
          type = lib.types.str;
          default = ".";
          description = "Working directory of `run` and the commands, relative to the remote home.";
        };
        scratch = lib.mkOption {
          type = lib.types.str;
          description = ''
            Absolute remote directory for put/get with a relative path,
            created 0700 on first use. Best on unsnapshotted storage.
          '';
        };
        commands = lib.mkOption {
          type = lib.types.attrsOf commandType;
          default = { };
          description = "Target-specific commands: `remote <target> <name> [ARG...]`.";
        };
      };
    }
  );

  reserved = [
    "run"
    "put"
    "get"
    "help"
    "close"
    "list"
  ];

  targetsJson =
    user: remotes:
    pkgs.writeText "hermes-remote-targets-${user}.json" (
      builtins.toJSON {
        targets = lib.mapAttrs (_: t: {
          inherit (t)
            host
            description
            cwd
            scratch
            ;
          commands = lib.mapAttrs (_: c: {
            inherit (c)
              kind
              prefix
              args
              timeout
              usage
              help
              ;
            script = if c.script == null then null else "${c.script}";
          }) t.commands;
        }) remotes;
      }
    );

  cliFor =
    user: remotes:
    pkgs.writeShellApplication {
      name = "remote";
      # jq programs are single-quoted on purpose.
      excludeShellChecks = [ "SC2016" ];
      runtimeInputs = with pkgs; [
        openssh
        jq
        coreutils
        gnutar
        util-linux
      ];
      text = ''
        export REMOTE_TARGETS=${targetsJson user remotes}
      ''
      + builtins.readFile ./remote.sh;
    };
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        {
          options.remotes = lib.mkOption {
            type = lib.types.attrsOf targetType;
            default = { };
            description = ''
              ssh targets of the agent's `remote` CLI (./remotes.nix), by
              name. The login itself (ssh_config, key, host key) is the
              operator's; this adds only the client.
            '';
          };
          config.extraPackages = lib.mkIf (config.remotes != { }) [ (cliFor name config.remotes) ];
        }
      )
    );
  };

  config.assertions =
    # profileSkills (./options.nix) names: a real profile id, a plain skill name.
    lib.concatLists (
      lib.mapAttrsToList (
        user: a:
        lib.concatLists (
          lib.mapAttrsToList (profile: skills: [
            {
              assertion = profile != "default" && builtins.match "[a-z0-9][a-z0-9_-]{0,63}" profile != null;
              message = "services.hyperhermes.agents.${user}.profileSkills.${profile}: not a named profile's id.";
            }
            {
              assertion = lib.all (n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" n != null) (lib.attrNames skills);
              message = "services.hyperhermes.agents.${user}.profileSkills.${profile}: skill names are [A-Za-z0-9][A-Za-z0-9._-]*.";
            }
          ]) a.profileSkills
        )
      ) cfg.agents
    )
    ++ lib.concatLists (
    lib.mapAttrsToList (
      user: a:
      lib.concatLists (
        lib.mapAttrsToList (
          target: t:
          [
            {
              assertion = !(lib.elem target reserved) && builtins.match "[A-Za-z0-9._-]+" target != null;
              message = "services.hyperhermes.agents.${user}.remotes.${target}: a target name is [A-Za-z0-9._-]+ and none of ${toString reserved}.";
            }
            {
              assertion = lib.hasPrefix "/" t.scratch;
              message = "services.hyperhermes.agents.${user}.remotes.${target}.scratch must be absolute.";
            }
          ]
          ++ lib.mapAttrsToList (cmd: c: {
            assertion = !(lib.elem cmd reserved) && (c.kind == "script") == (c.script != null) && c.prefix != [ ];
            message = "services.hyperhermes.agents.${user}.remotes.${target}.commands.${cmd}: not a reserved name, a non-empty prefix, and a script exactly for kind `script`.";
          }) t.commands
        ) a.remotes
      )
    ) cfg.agents
  );
}
