# Native hermes agents that share one shape: `hyper.hermesAgents.<name>`
# is one entry per agent, the machine lists only what differs.
#
# The shared shape, per agent:
#   - a normal login account <name>, reader on /vault/parquet (`vault-ro`,
#     ./vault-ids.nix),
#   - hermes runs NATIVE on the host (spaces modules/nixos/hermes/native.nix:
#     units hermes-agent-<name> / hermes-dashboard-<name> as that account,
#     state under /var/lib/hermes-microvm/<name>/state-vault), brain p0's
#     Qwen (the seed-once initialModel in ./hermes-common.nix), no
#     OpenRouter,
#   - the web dashboard on the shared host (./hermes-dashboard-public.nix;
#     pocket-id account = the agent name unless `dashboard.account` says
#     otherwise; passkey, enroll with pocket-id-enroll on edi),
#   - oh-my-pi on p0 through a per-user token copy (./inference-api-key.nix).
#
# uid: native mode binds the dashboard backend at 20000 + uid and nginx
# needs that port as a constant, so every agent's uid must be pinned. Set it
# here, or in the module that owns a shared identity (users/stefan-vault.nix,
# ./vault-ids.nix for momentum); the assertion below catches a missing pin.
# The id ladder lives in ./vault-ids.nix.
#
# Anything agent-specific that hermes-common.nix knows (telegram, extra
# .env entries) goes into `hermes`, which merges into
# hyper.hermes.users.<name>.
#
# Telegram (hermes gateway/authz_mixin.py): TELEGRAM_ALLOWED_USERS is the
# per-sender allowlist (numeric ids, @userinfobot), TELEGRAM_ALLOWED_CHATS
# limits group replies to one chat, TELEGRAM_HOME_CHANNEL receives
# proactive/cron output, TELEGRAM_REQUIRE_MENTION + TELEGRAM_MENTION_PATTERNS
# make a group bot react only when addressed (@mention, reply, or a wake word
# from the regex, matched case-insensitively). A DM bot needs only the
# defaults: a DM's chat id is the user's own id, so allowed_users doubles as
# the home channel. For a group bot, once on the Telegram side: @BotFather
# /newbot -> token; Bot Settings -> Group Privacy -> OFF; then add (or remove
# and re-add: privacy state is cached at join) the bot to the group. Fill
# the prompts with `clan vars generate <machine> --generator <generator>`.
{ config, lib, ... }:
let
  cfg = config.hyper.hermesAgents;
in
{
  imports = [
    ./hermes-common.nix
    ./hermes-dashboard-public.nix
  ];

  options.hyper.hermesAgents = lib.mkOption {
    default = { };
    description = "Native hermes agents on this machine, one login account each.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          uid = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Pinned uid; null when another module owns the account's identity.";
          };
          description = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Account description.";
          };
          sshKeys = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "SSH keys that log in as the agent account (hermes CLI, afk).";
          };
          shell = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = "Login shell; null keeps the site default.";
          };
          openrouter = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Hand the shared OpenRouter key to the agent.";
          };
          omp = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Install the account's p0 token copy for oh-my-pi.";
          };
          hermes = lib.mkOption {
            type = lib.types.deferredModule;
            default = { };
            description = "Merged into hyper.hermes.users.<name> (telegram, environment).";
          };
          dashboard = lib.mkOption {
            type = lib.types.deferredModule;
            default = { };
            description = "Merged into hyper.hermesDashboard.users.<name> (account, legacyHost).";
          };
        };
      }
    );
  };

  # No mkIf around this: every value is empty without agents.
  config = {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = config.users.users.${name}.uid != null;
      message = "hyper.hermesAgents.${name}: pin the uid (the dashboard port is 20000 + uid).";
    }) cfg;

    users.users = lib.mapAttrs (
      _: a:
      {
        isNormalUser = true;
        extraGroups = [ "vault-ro" ];
        openssh.authorizedKeys.keys = a.sshKeys;
      }
      // lib.optionalAttrs (a.uid != null) { inherit (a) uid; }
      // lib.optionalAttrs (a.description != null) { inherit (a) description; }
      // lib.optionalAttrs (a.shell != null) { inherit (a) shell; }
    ) cfg;

    # Function definitions: types.submodule reads a plain attrset as
    # config-only shorthand, where `imports` would be an unknown option.
    hyper.hermes.users = lib.mapAttrs (
      _: a:
      { ... }:
      {
        imports = [ a.hermes ];
        config = {
          native = true;
          inherit (a) openrouter;
        };
      }
    ) cfg;

    hyper.hermesDashboard.users = lib.mapAttrs (_: a: { ... }: { imports = [ a.dashboard ]; }) cfg;

    hyper.inferenceApiKey.users = lib.attrNames (lib.filterAttrs (_: a: a.omp) cfg);
  };
}
