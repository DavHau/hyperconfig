/*
  Pull requests from a space: `tea` (Gitea's own CLI) with one login per
  forge of `space.forges`, each with the bot account's API token from the
  space's credential (./default.nix passes it in from a prompted clan var,
  ./geninf-space.nix). git itself stays on ssh with the space's
  per-forge keys.

  The token never reaches the persistent home: tea keeps tokens only inline
  in its config, so <name>-forge-cli.service writes that config (0600, the
  user) to /run/<name>/tea/tea/config.yml on the guest's tmpfs, from the
  credentials, at every boot; `tea` on PATH is a wrapper pointing
  XDG_CONFIG_HOME there (only for tea). Logins are named after the forge's
  host and match git remotes on it (ssh_host), so in a checkout tea picks
  the right forge by itself; `--login <host>` elsewhere. A `tea login add`
  in the space would land in that tmpfs file and be gone at the next boot:
  logins are declared here.

  `space-forge-check` (./forge-check.sh): after a deploy, in the space,
  checks that each login authenticates as its bot and lists the
  repositories it can push to.

  The agent's how-to is the forge-prs skill (./forge-prs-skill/SKILL.md),
  linked into afk's skills by ./afk.nix.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.space;
  runDir = "/run/${cfg.name}/tea";
  configFile = "${runDir}/tea/config.yml";

  template = pkgs.writeText "${cfg.name}-tea-logins.json" (
    builtins.toJSON {
      logins = map (host: {
        name = host;
        url = "https://${host}";
        ssh_host = host;
        inherit (cfg.forges.${host}) user credential;
        default = host == cfg.defaultForge;
        # no /version round trip before every command (as `tea login add`
        # with its default `--no-version-check`)
        version_check = false;
      }) (lib.attrNames cfg.forges);
    }
  );

  writeConfig = pkgs.writeShellApplication {
    name = "${cfg.name}-forge-cli-config";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./forge-cli-config.sh;
  };

  tea = pkgs.symlinkJoin {
    name = "tea-${cfg.name}";
    paths = [ pkgs.tea ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/tea --set XDG_CONFIG_HOME ${runDir}
    '';
  };

  check = pkgs.writeShellApplication {
    name = "space-forge-check";
    runtimeInputs = [
      tea
      pkgs.jq
    ];
    text = ''
      set -- ${configFile}
    ''
    + builtins.readFile ./forge-check.sh;
  };
in
{
  options.space.forges = lib.mkOption {
    default = { };
    description = "Forge host (Gitea/Forgejo, https://<host>) -> the account the space acts as there and the credential with its API token: a `tea` login each.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          user = lib.mkOption {
            type = lib.types.str;
            description = "The account the token belongs to (`space-forge-check` expects it).";
          };
          credential = lib.mkOption {
            type = lib.types.str;
            description = "Name of the space credential holding the API token.";
          };
        };
      }
    );
  };

  options.space.defaultForge = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = if cfg.forges == { } then null else lib.head (lib.attrNames cfg.forges);
    defaultText = lib.literalMD "the first of `space.forges`";
    description = "tea's default login, outside a checkout of one of the forges.";
  };

  config = lib.mkIf (cfg.forges != { }) {
    assertions =
      lib.mapAttrsToList (host: f: {
        assertion = lib.elem f.credential cfg.credentials;
        message = "space.forges.${host}.credential: `${f.credential}` is not a credential of the ${cfg.name} space";
      }) cfg.forges
      ++ [
        {
          assertion = cfg.forges ? ${cfg.defaultForge};
          message = "space.defaultForge: ${cfg.defaultForge} is not in space.forges";
        }
      ];

    hyper.afk.extraSkills.forge-prs = ./forge-prs-skill;

    environment.systemPackages = [
      tea
      check
    ];

    systemd.services."${cfg.name}-forge-cli" = {
      description = "tea logins of ${cfg.user} (forge API tokens)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "${cfg.name}-secrets.service" ];
      after = [ "${cfg.name}-secrets.service" ];
      before = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "${cfg.name}-forge-cli" ''
          set -eu
          ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.user} ${runDir} ${runDir}/tea
          exec ${lib.getExe writeConfig} ${template} /run/${cfg.name}/secrets ${configFile} ${cfg.user}
        '';
      };
    };
  };
}
