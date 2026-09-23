# momentum's hermes agent on som: OpenRouter brain + a Telegram bot that
# lives in ONE group chat where several allow-listed people prompt it.
#
# Runs NATIVE (services.hermes-microvm.users.<n>.native, spaces
# modules/nixos/hermes/native.nix): host units hermes-agent-momentum /
# hermes-dashboard-momentum as the momentum account, no microVM. The state
# vault (/var/lib/hermes-microvm/momentum/state-vault) is the same path in
# both modes, so the sessions of the earlier VM carry over. One vault has
# one runner: after the switch that retired the VM, stop the still-loaded
# instance once (systemctl stop microvm@hermes-momentum) so the native
# units start. This file wires the telegram gating on top of the common
# secret plumbing (./hermes-common.nix: openrouter, p0, restart hooks).
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
{
  imports = [ ./hermes-common.nix ];

  hyper.hermes.users.momentum = {
    native = true;
    # Everything telegram-side is a secret (the chat id would let anyone
    # target the room; the wake words name the bot), so all ride in as
    # credentials. The patterns file holds ONE regex (alternation), not a
    # JSON list: the adapter treats a non-JSON value as a single pattern.
    telegram = {
      enable = true;
      # Pre-common var name; vars/per-machine/som/telegram/ holds the values.
      generator = "telegram";
      # On top of the common token + allowed_users:
      prompts = {
        chat_id = "Telegram group chat id the bot answers in (negative -100... supergroup id)";
        mention_patterns = "Regex of wake words (alternation, e.g. name1|name 1|nick), matched case-insensitively";
      };
      env = {
        TELEGRAM_ALLOWED_CHATS = "chat_id";
        # Proactive/cron output goes to the room as well.
        TELEGRAM_HOME_CHANNEL = "chat_id";
        TELEGRAM_MENTION_PATTERNS = "mention_patterns";
      };
    };
    environment.TELEGRAM_REQUIRE_MENTION = "true";
  };

  # Web dashboard at https://hermes.davhau.com/ for the pocket-id account
  # `momentum` (./hermes-dashboard-public.nix; passkey, enroll with
  # pocket-id-enroll on edi).
  hyper.hermesDashboard.users.momentum = { };

  # One shared session for the whole room. By default hermes keys a group
  # session per sender (agent:main:telegram:group:<chat>:<uid>, gateway/
  # session.py build_session_key), so members talk to separate agents and a
  # /model override only ever binds to the issuer's lane. Both flags must
  # agree - the adapter reads its own copy and the gateway drops routed
  # events whose key disagrees (gateway/platforms/base.py handle_message).
  #
  # services.hermes-microvm.settings is host-global (every agent on som,
  # merged into each config.yaml on every start). The other agents here are
  # DM bots or have no telegram group, so the shared-session flags change
  # nothing for them.
  services.hermes-microvm.settings = {
    group_sessions_per_user = false;
    gateway.platforms.telegram.extra.group_sessions_per_user = false;
  };
}
