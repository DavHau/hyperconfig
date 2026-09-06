# momentum's hermes microVM on som: OpenRouter brain + a Telegram bot that
# lives in ONE group chat where several allow-listed people prompt it.
#
# The VM itself is auto-provisioned (spaces desktop profile, one VM per
# normal user); this only wires its secrets and telegram gating. Defining
# secretEnv replaces the module's openrouter default, so OPENROUTER_API_KEY
# is re-listed (same shared var pi-chat uses, from pi-chat-openrouter.nix).
#
# Telegram authorization model (hermes gateway/authz_mixin.py):
#   TELEGRAM_ALLOWED_USERS   per-SENDER allowlist, applies in DMs and groups.
#                            Numeric ids only (ask @userinfobot), comma-separated.
#   TELEGRAM_ALLOWED_CHATS   the bot answers group messages only from this chat
#                            (DMs unaffected). Negative -100... supergroup id.
#   TELEGRAM_REQUIRE_MENTION + TELEGRAM_MENTION_PATTERNS: the bot only reacts
#                            when addressed - @mention, a reply to it, or a
#                            wake word from the secret regex (adapter.py
#                            _should_process_message; compiled IGNORECASE).
#                            Without the gate the wake word is meaningless:
#                            every message is a prompt.
# Deliberately NOT set: TELEGRAM_GROUP_ALLOWED_CHATS (authorizes every member
# of the chat regardless of sender) and observe mode (needs the former).
#
# Telegram side, once: @BotFather /newbot -> token; Bot Settings -> Group
# Privacy -> OFF; then add (or remove and re-add - privacy state is cached at
# join) the bot to the group. Chat id: add @userinfobot to the group briefly.
#
#   clan vars generate som --generator telegram   # token, allowed_users, chat_id, mention_patterns
{ config, ... }:
let
  telegram = config.clan.core.vars.generators.telegram;
  vm = "microvm@hermes-momentum.service";
in
{
  clan.core.vars.generators.openrouter.files.apikey.restartUnits = [ vm ];

  # Per-machine generator (share defaults to false): som's bot, not amy's.
  clan.core.vars.generators.telegram = {
    prompts.token = {
      type = "hidden";
      persist = true;
      description = "Telegram bot token from @BotFather";
    };
    prompts.allowed_users = {
      type = "hidden";
      persist = true;
      description = "Comma-separated numeric Telegram user ids allowed to prompt the bot";
    };
    prompts.chat_id = {
      type = "hidden";
      persist = true;
      description = "Telegram group chat id the bot answers in (negative -100... supergroup id)";
    };
    prompts.mention_patterns = {
      type = "hidden";
      persist = true;
      description = "Regex of wake words (alternation, e.g. name1|name 1|nick), matched case-insensitively";
    };
    files.token.restartUnits = [ vm ];
    files.allowed_users.restartUnits = [ vm ];
    files.chat_id.restartUnits = [ vm ];
    files.mention_patterns.restartUnits = [ vm ];
  };

  services.hermes-microvm.users.momentum = {
    # Everything telegram-side is a secret (the chat id would let anyone
    # target the room; the wake words name the bot), so all ride in as
    # credentials. The patterns file holds ONE regex (alternation), not a
    # JSON list: the adapter treats a non-JSON value as a single pattern.
    secretEnv = {
      OPENROUTER_API_KEY = config.clan.core.vars.generators.openrouter.files.apikey.path;
      TELEGRAM_BOT_TOKEN = telegram.files.token.path;
      TELEGRAM_ALLOWED_USERS = telegram.files.allowed_users.path;
      TELEGRAM_ALLOWED_CHATS = telegram.files.chat_id.path;
      # Proactive/cron output goes to the room as well.
      TELEGRAM_HOME_CHANNEL = telegram.files.chat_id.path;
      TELEGRAM_MENTION_PATTERNS = telegram.files.mention_patterns.path;
    };
    environment.TELEGRAM_REQUIRE_MENTION = "true";
  };
}
