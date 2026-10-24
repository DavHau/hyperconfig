# som's native hermes agents. The shared shape and the Telegram how-to are in
# ../../modules/nixos/hermes-agents.nix; entries here carry only what differs.
# Who signs in to which agent's dashboard: ./hermes-dashboards.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dashboards = import ./hermes-dashboards.nix;
  # The clan sshd instance fills root's list; accounts without keys of their
  # own reuse it.
  adminKeys = config.users.users.root.openssh.authorizedKeys.keys;
  # hermes-desktop on the dave machines dials dave-hermes and joe over ssh
  # with a shared restricted key (../../modules/nixos/hermes-desktop owns the
  # key and the rationale; dave.nix imports it here too). Its bootstrap needs
  # command execution plus one loopback -L forward to the port
  # `hermes serve --port 0` picks, nothing else: no pty, no agent/X11
  # forwarding.
  desktopKey = ''restrict,port-forwarding,permitopen="127.0.0.1:*" ${
    config.clan.core.vars.generators.hermes-desktop-ssh.files."key.pub".value
  }'';
in
{
  imports = [
    ../../modules/nixos/hermes-agents.nix
    ../../modules/nixos/lightning-wallet.nix
    # stefan's account (uid, vault-ro) is shared with vit.
    ../../modules/nixos/users/stefan-vault.nix
  ];

  hyper.hermesAgentsGpuHost = "vit.d";

  # One shared phoenixd Lightning wallet for every agent below.
  hyper.lightningWallet.enable = true;

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

    adam = {
      uid = 1105;
      description = "adam - hermes agent, read-only vault consumer";
      sshKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICwDM+8310VQgkMpUu1Oz+ihDBBfCZ/akKMmUIPLgevR adambartnik@Adams-MacBook-Pro-2"
      ];
    };

    j = {
      uid = 1106;
      description = "j - hermes agent, read-only vault consumer";
      sshKeys = [
        # j's GitHub keys (fetched 2026-09-25)
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOirp5rceowRPLnkCT2/vlTPgxtRWPeKdMIPnJ7ixJfi j"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOEkNzWyFiIeI3dtF5nteYbwsvQTpBUdJ5Ona3Hne0wf j"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAINh8AcDMFJ9YqXfZoCWp7qOBVBRYD0raLeo7oetwBcwDAAAABHNzaDo= j"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIOtVR8T3XmFOIgHNpu5sHJg50ujmKCKER2OZOY2oynL+AAAABHNzaDo= j"
      ];
    };

    willi = {
      uid = 1108;
      description = "willi - hermes agent";
      sshKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJShRmVEINmRgiXrhpVINJZGw7ZJq3HcCk8kmDM+1B3x reuss@PCBüro"
      ];
    };

    # domi: logs in with the admin keys until he has keys of his own.
    domi = {
      uid = 1109;
      description = "domi - hermes agent";
      sshKeys = adminKeys;
    };

    rti = {
      uid = 1110;
      description = "rti - hermes agent";
      sshKeys = [
        # github.com/rti.keys (fetched 2026-10-02)
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFT8SLyvX8PKh4Gm+hPb8XrSyXSdHnsF6uWDo8G28WUFAAAABHNzaDo= rti"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO/KhqU4po6beEkEDFE7ncoLHNwkR+Or+SDXXnZJ/1djAAAABHNzaDo= rti"
        "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIGqhMxHJMNbzSFv9BjPKlpNcQqumDK2q+dvGrhbkJx4gAAAABHNzaDo= rti"
      ];
    };

    chris = {
      uid = 1111;
      description = "chris - hermes agent";
      sshKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyDZ+BWILWGSvZ2ArfmNy50tTuBvFw22eyGFUnmuSCvadHrSPsN67q3iVQ66E5OWqOg4luY4Noq+HkMI0/AG+Y89Fp/2U1B6LETVxV8c70gZXEltiPFhx/BcW737pGMUgHwf22On2Dh9rCZpzPjyMYqF7SJNaoUFEnKntPR97gJhzrGTNggE/Td3piHDcze7WFrFfdlbmMy8COIk2aZ0C7+Wy1D1DE06z54yIZIaelBWJrujeqxP09yDiRlSNEZgNVu/AyzsGoQFwUP9nhjG7PEhvQrWAmlQDxPJRIahLxrrBEl0QOnnAup1gf9OUuxb39WDzN6ejJy3GkcwiAfhfr chris"
      ];
    };

    b3x = {
      uid = 1112;
      description = "b3x - hermes agent";
      sshKeys = [
        # github.com/theanxy.keys (fetched 2026-10-19)
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL98qbBMVca+vmDMSGYTIQVqncMSTrJZlMLXL430UFaJ theanxy"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4W5V2wnXVKvbablE7CM4soDYfdqA7DUbB/04VzrN1r theanxy"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlGX2PY0MKopFzB280bqIXo7SpNKntS0aLbWgLivCKJ wojtek@wojtek14-2.local"
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
      sshKeys = adminKeys ++ [ desktopKey ];
    };

    # joe: dave's former amy microVM agent (hermes-grmpf), its state and
    # workspace copied over when amy's microVM was retired. Untrusted like
    # dave-hermes, so its own account; dave signs in to its dashboard.
    joe = {
      uid = 1113;
      description = "joe - dave's hermes agent (ex amy microVM)";
      sshKeys = adminKeys ++ [ desktopKey ];
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

  # The daily Open LLM brief cron job (moved from amy's microVM) scans its
  # blog feeds with blogwatcher-cli; the feed db sits in the account home.
  users.users.dave-hermes.packages = [ (pkgs.callPackage ../../pkgs/blogwatcher-cli { }) ];

  # Each agent's dashboard account; the inventory reads the same file for
  # the pocket-id clients and groups.
  hyper.hermesDashboard.users = lib.mapAttrs (_: account: { inherit account; }) dashboards.accounts;

  # Only the native agents above, on the local module (hermes-native, with
  # its loopback SearXNG). spaces' microVM module and its slirp-facing
  # SearXNG stay off: spaces would otherwise give every normal user (dave,
  # agent, hsjobeki, nixremote, ...) a hermes microVM.
  services.hermes-native.enable = true;
  # browser_solve_captcha's model: CaptchaKraken on vit
  # (../../modules/nixos/captchakraken-server.nix, which admits som's
  # yggdrasil address). The agents' uids leave through Mullvad, whose kill
  # switch passes yggdrasil (200::/7).
  services.hermes-native.captchaSolver.baseUrl = "http://vit.d:8096/v1";
  # read_file's scanned-PDF OCR and the agents' `ocr` CLI: Typhoon OCR on
  # vit (../../modules/nixos/ocr-server), same yggdrasil path and
  # admission as the captcha model.
  services.hermes-native.ocr.baseUrl = "http://vit.d:8098";
  services.hermes-microvm.enable = false;
  services.spaces-searxng.enable = false;

  # Host-wide (merged into every agent's config.yaml): one shared session per
  # group chat. By default hermes keys a group session per sender, so
  # momentum's room members would talk to separate agents and a /model
  # override would bind only to the issuer's lane. Both flags must agree: the
  # adapter reads its own copy and the gateway drops routed events whose key
  # disagrees. The other agents are DM bots or dashboard/SSH only, so the
  # flags change nothing for them.
  services.hermes-native.settings = {
    group_sessions_per_user = false;
    gateway.platforms.telegram.extra.group_sessions_per_user = false;
  };
}
