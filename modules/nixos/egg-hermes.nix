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

  # The spaces desktop profile auto-provisions every normal user, which
  # merges with the entry below. uid pinned to what som allocated: native
  # mode binds the dashboard backend at 20000 + uid, and
  # ./hermes-dashboard-public.nix needs that port as a constant.
  users.users.egg = {
    isNormalUser = true;
    uid = 1004;
    # Read-only on /vault/parquet (./vault-ids.nix).
    extraGroups = [ "vault-ro" ];
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

  # Web dashboard at https://hermes.davhau.com/ (pocket-id account `egg`);
  # egg.davhau.com was the original address and redirects there.
  hyper.hermesDashboard.users.egg.legacyHost = "egg.davhau.com";

  # oh-my-pi: the `afk` wrapper (./afk.nix, on PATH for every user via
  # dave.nix) exports P0_API_KEY and ships a models.yml with the p0
  # provider (./omp-common.nix). The var file itself is owner-only (dave);
  # a per-user copy at /run/inference-api-key/egg/token gives egg's
  # wrapper p0's Qwen (./inference-api-key.nix).
  hyper.inferenceApiKey.users = [ "egg" ];
}
