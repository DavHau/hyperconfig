# egg's (fabien, github.com/allouis) hermes agent on som: runs NATIVE (services.hermes-microvm
# users.<n>.native, spaces modules/nixos/hermes/native.nix) — host units
# hermes-agent-egg / hermes-dashboard-egg as the egg account, no
# microVM, full host access. Brain: p0's Qwen (the common initialModel in
# ./hermes-common.nix; seeded once into the fresh state under
# /var/lib/hermes-microvm/egg/state-vault). No OpenRouter.
#
# Control channel: a Telegram DM bot. The chat id of a DM is egg's own
# numeric user id, so one prompt serves as the sender allowlist and as the
# home channel for proactive/cron output.
#
#   clan vars generate som --generator telegram-egg   # token, allowed_users
{ lib, ... }:
{
  imports = [ ./hermes-common.nix ];

  # Plain account; native mode derives its backend ports from the runtime
  # uid, so no static uid is needed. The spaces desktop profile
  # auto-provisions every normal user, which merges with the entry below.
  users.users.egg = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      # github.com/allouis.keys (fetched 2026-09-09)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBcx+vaa7+HgTcP0tpFpgs4SpzoViy8/fERFL6YWBfb0 allouis"
    ];
  };

  hyper.hermes.users.egg = {
    native = true;
    openrouter = false;
    telegram = {
      enable = true;
      prompts.allowed_users = "egg's numeric Telegram user id (DM chat id; ask @userinfobot)";
      env.TELEGRAM_HOME_CHANNEL = "allowed_users";
    };
  };

  # oh-my-pi: the afk-wrapped `omp` (./afk.nix, on PATH for every user via
  # dave.nix) exports P0_API_KEY and ships a models.yml with the p0
  # provider (./omp-common.nix). The var file itself is owner-only (dave);
  # a per-user copy at /run/inference-api-key/egg/token gives egg's
  # wrapper p0's Qwen (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "egg" ];
}
