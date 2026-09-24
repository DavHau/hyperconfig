# som's native hermes agents. The shared shape and the Telegram how-to are in
# ../../modules/nixos/hermes-agents.nix; entries here carry only what differs.
{
  config,
  inputs,
  ...
}:
let
  # The clan admin role fills root's list; accounts without keys of their
  # own reuse it.
  adminKeys = config.users.users.root.openssh.authorizedKeys.keys;
  # amy's hermes-desktop dials dave-hermes over ssh (spaces' SSH connection
  # kind; hermes/desktop-connections.nix on amy owns the key and the
  # rationale). Its bootstrap needs command execution plus one loopback -L
  # forward to the port `hermes serve --port 0` picks, nothing else: no pty,
  # no agent/X11 forwarding.
  desktopKey = inputs.self.nixosConfigurations.amy.config.clan.core.vars.generators.hermes-desktop-ssh.files."key.pub".value;
in
{
  imports = [
    ../../modules/nixos/hermes-agents.nix
    # stefan's account (uid, vault-ro) is shared with vit.
    ../../modules/nixos/users/stefan-vault.nix
  ];

  hyper.hermesAgentsGpuHost = "vit.d";

  hyper.hermesAgents = {
    # uid and vault-ro from users/stefan-vault.nix.
    stefan = { };

    pinpox = {
      uid = 1104;
      description = "pinpox - hermes agent, read-only vault consumer";
      sshKeys = [
        # github.com/pinpox.keys (fetched 2026-09-22)
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILSJJs01RqXS6YE5Jf8LUJoJVBxFev3R18FWXJyLeYJE pinpox"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKact4Wb6MmbpIW1rBocXP5Knrn7zJeXmIafykQe5Ke pinpox"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFh6rVY1K340DICKUa7jVOsoZcbD8SzEUFZlXDUX1lSRC4KiRz3MTwvV6PLVIlC17yOVgfDmx+5qgRa6iowN8nI= pinpox"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnbhSKvtaQVPAyvv+lHCx+At0Gm3yA8jmSgUxsIgN3s pinpox"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCdOfrnazSXp7ZmHcePXSd4leP3Qafr4fmDr3w+AxwRChSn1zzLPjV8CvD/PdMU7jQA0HS/1ItREurmZCKS/ZnQ= pinpox"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIGzA1cg3xTlrzYrEY9CNBiWqu6axpaMBaJfHqZQvB4RHAAAABHNzaDo= pinpox"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCTwBH0KIRE+9SC4n7hRAGAA7Lf/+PuCHFZzZDajy9lmYrcQdvD5SgP6Q5OikUxycniI0Zse5Xeitq9qkJNg6Lw= pinpox"
      ];
    };

    # egg (fabien, github.com/allouis): controlled through a Telegram DM bot.
    egg = {
      uid = 1004;
      sshKeys = [
        # github.com/allouis.keys (fetched 2026-09-09)
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBcx+vaa7+HgTcP0tpFpgs4SpzoViy8/fERFL6YWBfb0 allouis"
      ];
      hermes.telegram = {
        enable = true;
        prompts.allowed_users = "egg's numeric Telegram user id (DM chat id; ask @userinfobot)";
        env.TELEGRAM_HOME_CHANNEL = "allowed_users";
      };
    };

    # dave's agent, in its OWN account, not the dave login: the agent is
    # untrusted and native mode gives it everything the owning uid has.
    dave-hermes = {
      uid = 1005;
      description = "dave's hermes agent";
      sshKeys = adminKeys ++ [
        ''restrict,port-forwarding,permitopen="127.0.0.1:*" ${desktopKey}''
      ];
      dashboard.account = "dave";
    };

    # momentum: OpenRouter brain + a Telegram bot in ONE group chat where
    # several allow-listed people prompt it. Identity (uid 1100, vault-ro)
    # in ../../modules/nixos/vault-ids.nix; logs in with the admin keys
    # until the consumer has one of their own.
    momentum = {
      sshKeys = adminKeys;
      openrouter = true;
      hermes = {
        # Everything telegram-side is a secret (the chat id would let anyone
        # target the room; the wake words name the bot), so all ride in as
        # credentials. The patterns file holds ONE regex (alternation), not
        # a JSON list: the adapter treats a non-JSON value as one pattern.
        # Deliberately NOT set: TELEGRAM_GROUP_ALLOWED_CHATS (authorizes
        # every member of the chat regardless of sender) and observe mode.
        telegram = {
          enable = true;
          # Pre-common var name; vars/per-machine/som/telegram/ holds the values.
          generator = "telegram";
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
    };
  };

  # Host-wide (merged into every agent's config.yaml): one shared session per
  # group chat. By default hermes keys a group session per sender, so
  # momentum's room members would talk to separate agents and a /model
  # override would bind only to the issuer's lane. Both flags must agree: the
  # adapter reads its own copy and the gateway drops routed events whose key
  # disagrees. The other agents are DM bots or dashboard/SSH only, so the
  # flags change nothing for them.
  services.hermes-microvm.settings = {
    group_sessions_per_user = false;
    gateway.platforms.telegram.extra.group_sessions_per_user = false;
  };
}
