# Provider keys for Dave's harnesses (afk, omp, pi): one mechanism for every
# API key a models.yml provider resolves by running a command, so no key
# sits in a config file or the store.
#
# `hyper.providerKeys.<name>` is one key: a clan var file (`generator` /
# `file`) and a `<name>-api-key` command that prints it (exit 1 when nothing
# is readable). models.yml names the command as `apiKey: "!<name>-api-key"`
# (see omp-common.nix). Who else reads the var file:
#
#   delivery = "group":    the file is 0440 owner:<name>-api-key; the group
#                          holds the desktop owner and the fleet `agent`
#                          account (./agent-user.nix).
#   delivery = "per-user": the file is 0400 owner only; every account in
#                          `users` gets a private copy from a root oneshot
#                          `<generator>-<user>` at `userKeyPath <user>`
#                          (re-run on rotation via restartUnits); the
#                          command reads the caller's copy first.
#
# Consumers iterate `config.hyper.providerKeys` (sbox binds in ./sbox.nix,
# the house's roFiles in ./houses-grmpf.nix); a new key is one more entry
# below, never a new module. Owner and group must exist on every importing
# machine: the age backend's decrypt script (clan-core
# nixosModules/clanCore/vars/secret/age.nix) runs under `set -e` and chowns
# each file, so an unknown one aborts it and leaves the host's remaining
# secrets undecrypted.
#
# Also imported where clan is not (the infra-space container and the named
# spaces, ./spaces/afk.nix): there `keyFile` points at a credential the host
# passes in, and the var, its group and owner are left out.
#
# The keys:
#
#   p0          fleet inference endpoint (https://inference.p0.contact; the
#               server half is project-zero modules/inference-api-key.nix).
#               Prompted, shared: paste the same string as project-zero,
#                 clan vars generate <machine> --generator inference-api-key
#   teamclaude  client key for the TeamClaude pooled Claude subscription
#               gateway (./teamclaude-gateway on som, which accepts it as the
#               static client key `hyperconfig`). Generated, shared. Rotate:
#                 clan vars generate som --generator teamclaude-api-key --regenerate
#               and deploy som plus every machine importing this module.
#   openrouter  the shared OpenRouter key; the var (`openrouter/apikey`,
#               prompted) is declared in ./pi-chat-openrouter.nix. One key
#               for the desktops, the containers and som's hermes agents (a
#               decision: spend is not attributable per context; keep a
#               credit limit on it in OpenRouter). Rotate:
#                 clan vars generate som --generator openrouter --regenerate
#               then deploy som, amy and vit.
{ config, lib, pkgs, options, ... }:
let
  cfg = config.hyper.providerKeys;
  hasClan = options ? clan;
  desktopOwner = config.hyper.daveDesktop.user or (if config.users.users ? grmpf then "grmpf" else "dave");

  keyType = lib.types.submodule ({ name, config, ... }: {
    options = {
      command = lib.mkOption {
        type = lib.types.str;
        default = "${name}-api-key";
        description = "The command that prints the key (models.yml `apiKey: \"!<command>\"`).";
      };
      generator = lib.mkOption {
        type = lib.types.str;
        description = "The clan vars generator holding the key (never rename: shared secrets).";
      };
      file = lib.mkOption {
        type = lib.types.str;
        description = "The generator's file holding the bare key.";
      };
      delivery = lib.mkOption {
        type = lib.types.enum [ "group" "per-user" ];
        default = "group";
        description = "How accounts besides the owner read the key (see the module header).";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = config.command;
        description = "The group reading the var file (delivery = group).";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = desktopOwner;
        defaultText = lib.literalExpression "config.hyper.daveDesktop.user";
        description = "Owner of the var file.";
      };
      label = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "What the key is, for the per-user copy units' descriptions.";
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Accounts (besides the owner) that get a private copy (delivery = per-user).";
      };
      userKeyPath = lib.mkOption {
        type = lib.types.functionTo lib.types.str;
        readOnly = true;
        default = user: "/run/${config.generator}/${user}/${config.file}";
        description = "Where a user's copy lands; the command and sbox read it with the runtime user name.";
      };
      keyFile = lib.mkOption {
        type = lib.types.str;
        default = config._clanPath;
        defaultText = lib.literalExpression "config.clan.core.vars.generators.<generator>.files.<file>.path";
        description = "The key file the command prints (and per-user copies are made from).";
      };
      _clanPath = lib.mkOption {
        type = lib.types.str;
        internal = true;
        readOnly = true;
        default = outer.clan.core.vars.generators.${config.generator}.files.${config.file}.path;
        defaultText = lib.literalExpression "config.clan.core.vars.generators.<generator>.files.<file>.path";
      };
    };
  });
  outer = config;

  unit = k: user: "${k.generator}-${user}";

  command = k: pkgs.writeShellApplication {
    runtimeInputs = [ pkgs.coreutils ];
    name = k.command;
    text =
      if k.delivery == "per-user" then ''
        for f in ${k.userKeyPath "$(id -un)"} ${k.keyFile}; do
          [ -r "$f" ] && exec cat "$f"
        done
        echo "${k.command}: no readable ${k.generator} ${k.file} for $(id -un)" >&2
        exit 1
      '' else ''
        [ -r ${k.keyFile} ] && exec cat ${k.keyFile}
        echo "${k.command}: ${k.keyFile} is not readable for $(id -un)" >&2
        exit 1
      '';
  };

  copyUnits = k: lib.listToAttrs (map (user:
    lib.nameValuePair (unit k user) {
      description = "${k.label} copy for ${user}";
      wantedBy = [ "multi-user.target" ];
      # clan-core's age backend decrypts the var in its setupSecrets
      # activation snippet, before any unit (re)starts; the file is there
      # once the target runs.
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "${k.generator}/${user}";
        RuntimeDirectoryPreserve = true;
        RuntimeDirectoryMode = "0755";
        ExecStart = "${pkgs.coreutils}/bin/install -m 0400 -o ${user} -g root ${k.keyFile} ${k.userKeyPath user}";
      };
    }) k.users);

  ordered = first: let f = lib.filter (n: cfg ? ${n}) first; in f ++ lib.subtractLists f (lib.attrNames cfg);

  groupKeys = lib.filterAttrs (_: k: k.delivery == "group") cfg;
  perUserKeys = lib.filterAttrs (_: k: k.delivery == "per-user") cfg;

  # Every path a key is read from (the var file, a user's copy with the
  # runtime user name): what a sandbox must bind for the command to work.
  # In the order the consumers listed them before this module (keeps
  # houses-grmpf's landlock rules unchanged); later keys come after them.
  keyPaths = user: lib.concatMap (n: let k = cfg.${n}; in
    [ k.keyFile ] ++ lib.optional (k.delivery == "per-user") (k.userKeyPath user)) (ordered [ "p0" "teamclaude" "openrouter" ]);
in
{
  options.hyper.providerKeys = lib.mkOption {
    type = lib.types.attrsOf keyType;
    default = { };
    description = "Provider API keys printed by `<name>-api-key` commands (see the module header).";
  };
  options.hyper.providerKeyPaths = lib.mkOption {
    type = lib.types.functionTo (lib.types.listOf lib.types.str);
    readOnly = true;
    default = keyPaths;
    description = "user -> every file the key commands read for that user (var files and per-user copies), for sandbox binds.";
  };

  config = lib.mkMerge [
    {
      hyper.providerKeys = {
        p0 = {
          generator = "inference-api-key";
          file = "token";
          delivery = "per-user";
          label = "inference endpoint token";
        };
        teamclaude = {
          generator = "teamclaude-api-key";
          file = "key";
        };
        openrouter = {
          generator = "openrouter";
          file = "apikey";
        };
      };

      # The order the three per-key modules this replaced ended up in (keeps
      # system-path's store path unchanged); later keys come after them.
      environment.systemPackages = map (n: command cfg.${n}) (ordered [ "openrouter" "teamclaude" "p0" ]);
      systemd.services = lib.concatMapAttrs (_: copyUnits) perUserKeys;
    }
    (lib.optionalAttrs hasClan {
      # The vars this module owns (openrouter's is ./pi-chat-openrouter.nix's).
      # Their files' owner, group and mode come from the entries below.
      clan.core.vars.generators.inference-api-key = {
        share = true;
        # A persisted prompt IS the file: no generator script, so the var
        # holds exactly the token and nothing else.
        prompts.token = {
          description = "Bearer token for https://inference.p0.contact (same value as project-zero)";
          type = "hidden";
          persist = true;
        };
      };
      clan.core.vars.generators.teamclaude-api-key = {
        share = true;
        runtimeInputs = [ pkgs.openssl ];
        # `sk-ant-oat01-` is load-bearing, as for the gateway's operator
        # key: omp presents as Claude Code (the only shape Anthropic
        # accepts subscription OAuth in) only when its key looks like a
        # subscription token, and sends it as `Authorization: Bearer`.
        script = ''
          printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
        '';
      };
    })
    (lib.optionalAttrs hasClan {
      # Every account that runs a harness reads a group key: the desktop user
      # and, where it exists, the fleet `agent` account (./agent-user.nix),
      # which gets afk's models.yml too.
      users.groups = lib.mapAttrs' (_: k:
        lib.nameValuePair k.group {
          members = [ k.owner ] ++ lib.optional (config.users.users ? agent) "agent";
        }) groupKeys;

      clan.core.vars.generators = lib.mapAttrs' (_: k:
        lib.nameValuePair k.generator {
          files.${k.file} = {
            inherit (k) owner;
          } // (if k.delivery == "group" then {
            inherit (k) group;
            mode = "0440";
          } else {
            mode = "0400";
            # Sorted: definition order across importing modules is not
            # stable through the submodule.
            restartUnits = map (u: "${unit k u}.service") (lib.sort lib.lessThan k.users);
          });
        }) cfg;
    })
  ];
}
