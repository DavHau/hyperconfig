# Site-wide Hermes wiring shared by every machine that runs agents on the
# spaces hermes module (inputs.spaces.nixosModules.hermes, pulled in by the
# spaces desktop profile via dave.nix): the p0 inference provider, the
# default brain, and per-user secret plumbing declared once as
# `hyper.hermes.users.<name>` instead of hand-written secretEnv +
# clan generator + restartUnits triples in every machine file.
#
# Per user this derives:
#   - a clan vars generator (`telegram.generator`, hidden persisted prompts)
#     when telegram is on; `clan vars generate <machine> --generator <name>`
#     fills it,
#   - services.hermes-microvm.users.<name> with `native` and a secretEnv of
#     P0_API_KEY (always: providers.p0 below names it), the telegram
#     files mapped through `telegram.env`, and OPENROUTER_API_KEY only when
#     `openrouter` is on (an explicit secretEnv drops the spaces default),
#   - restartUnits on every generator the user consumes, aimed at the
#     runner: hermes-agent-<name>.service (native) or microvm@hermes-<name>
#     (VM).
#
# Host-global (one value per machine, the spaces module has no per-user
# settings): providers.p0 and the seed-once initialModel. initialModel is
# mkDefault so a site can keep another brain (amy: vit's llama-swap).
# Seeding is safe on a host with existing agents: modelSeedScript writes
# only when config.yaml has no `model` key.
#
# Telegram authorization (hermes gateway/authz_mixin.py): TELEGRAM_ALLOWED_USERS
# is the per-sender allowlist (DMs and groups, numeric ids from
# @userinfobot); TELEGRAM_ALLOWED_CHATS restricts group replies to one chat;
# TELEGRAM_HOME_CHANNEL receives proactive/cron output. The defaults cover
# a DM bot; a group bot adds prompts and env mappings (see momentum-hermes.nix).
{ config, lib, ... }:
let
  cfg = config.hyper.hermes;
  inference = config.clan.core.vars.generators.inference-api-key;
  openrouter = config.clan.core.vars.generators.openrouter;

  runnerUnit = name: u: if u.native then "hermes-agent-${name}.service" else "microvm@hermes-${name}.service";
  telegramUsers = lib.filterAttrs (_: u: u.telegram.enable) cfg.users;
in
{
  options.hyper.hermes.users = lib.mkOption {
    default = { };
    description = "Hermes agents on this machine with their secret wiring.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            native = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Run on the host (services.hermes-microvm.users.<name>.native) instead of a microVM.";
            };
            openrouter = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Hand the shared openrouter/apikey var to the agent as OPENROUTER_API_KEY.";
            };
            environment = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Non-secret .env entries (services.hermes-microvm.users.<name>.environment).";
            };
            telegram = {
              enable = lib.mkEnableOption "a Telegram bot for this agent";
              generator = lib.mkOption {
                type = lib.types.str;
                default = "telegram-${name}";
                description = "clan vars generator name (per-machine). Pre-existing bots keep their old name.";
              };
              prompts = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                description = ''
                  Prompt name -> description. Every prompt is a hidden,
                  persisted var. `token` and `allowed_users` are always
                  present (per-leaf mkDefault: override the text, or add
                  more entries — a site definition merges, it does not
                  replace).
                '';
              };
              env = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                description = ''
                  Env var -> prompt name; each rides into the agent as a
                  credential. TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS
                  are always mapped; site entries merge in.
                '';
              };
            };
          };
          config.telegram = {
            prompts = {
              token = lib.mkDefault "Telegram bot token from @BotFather";
              allowed_users = lib.mkDefault "Comma-separated numeric Telegram user ids allowed to prompt the bot";
            };
            env = {
              TELEGRAM_BOT_TOKEN = lib.mkDefault "token";
              TELEGRAM_ALLOWED_USERS = lib.mkDefault "allowed_users";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg.users != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        name: u:
        lib.mapAttrsToList (env: prompt: {
          assertion = !u.telegram.enable || u.telegram.prompts ? ${prompt};
          message = "hyper.hermes.users.${name}.telegram.env.${env} names prompt '${prompt}', which is not in telegram.prompts.";
        }) u.telegram.env
      ) cfg.users
    );

    clan.core.vars.generators = lib.mkMerge (
      [
        {
          inference-api-key.files.token.restartUnits = lib.mapAttrsToList runnerUnit cfg.users;
          openrouter.files.apikey.restartUnits = lib.mapAttrsToList runnerUnit (
            lib.filterAttrs (_: u: u.openrouter) cfg.users
          );
        }
      ]
      ++ lib.mapAttrsToList (name: u: {
        ${u.telegram.generator} = {
          prompts = lib.mapAttrs (_: description: {
            inherit description;
            type = "hidden";
            persist = true;
          }) u.telegram.prompts;
          files = lib.mapAttrs (_: _: { restartUnits = [ (runnerUnit name u) ]; }) u.telegram.prompts;
        };
      }) telegramUsers
    );

    services.hermes-microvm = {
      settings.providers.p0 = {
        base_url = "https://inference.p0.contact/v1";
        # Env var NAME, never the token: resolved by the agent from the
        # credential-seeded .env (hermes_cli/runtime_provider.py).
        key_env = "P0_API_KEY";
        default_model = "Qwen3.8-27B-FP8";
        # Qwen only reasons when the chat template is told to; hermes spelling
        # of omp's compat.thinkingFormat: qwen-chat-template (omp-common.nix).
        extra_body.chat_template_kwargs.enable_thinking = true;
      };
      # Above the spaces module's own mkDefault (llama-swap g9v3:3b on a
      # desktop), below a plain site definition (amy's vit seed).
      initialModel = lib.mkOverride 900 {
        provider = "p0";
        base_url = "https://inference.p0.contact/v1";
        default = "Qwen3.8-27B-FP8";
      };

      users = lib.mapAttrs (name: u: {
        inherit (u) native environment;
        secretEnv =
          {
            P0_API_KEY = inference.files.token.path;
          }
          // lib.optionalAttrs u.openrouter {
            OPENROUTER_API_KEY = openrouter.files.apikey.path;
          }
          // lib.optionalAttrs u.telegram.enable (
            lib.mapAttrs (
              _: prompt: config.clan.core.vars.generators.${u.telegram.generator}.files.${prompt}.path
            ) u.telegram.env
          );
      }) cfg.users;
    };
  };
}
