# som's hermes agents on hyperhermes (services.hyperhermes, the ./hyperhermes
# flake): one login account per agent, the gateway and dashboard natively
# as that account, state under /var/lib/hermes/<agent>/state. Entries here
# carry what differs per agent; the uids are in ./hermes-agents-data.nix,
# which vit's GPU host reads too. Who signs in to which agent's dashboard,
# and the front door: ./hermes-dashboards.nix. The brain:
# ./hermes-inference.nix.
#
# Site shape on top of hyperhermes, per agent:
#   - reader on /vault/parquet (`vault-ro`, ../../modules/nixos/vault-ids.nix),
#   - its own ssh key (clan var hermes-agent-ssh-<agent>,
#     hyperhermes.nixosModules.clan) for vit, the GPU host, where it has an
#     account of the same uid (../../modules/nixos/hermes-agents-gpu-host.nix)
#     and which the gpu-host skill teaches,
#   - the web dashboard at https://<agent>.<domain>/ (hyperhermes'
#     dashboards, behind the clan's pocket-id: hyper.oidc) and 10
#     published loopback ports (../../modules/nixos/hermes-agents-serve.nix),
#   - the web tools (hyperhermes.nixosModules.browser).
#
# Messengers (Telegram, ...) are not declared here: each agent's owner
# connects them on the Channels page of the agent's dashboard.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  data = import ./hermes-agents-data.nix;
  dashboards = import ./hermes-dashboards.nix;
  # The clan sshd instance fills root's list; accounts without keys of their
  # own reuse it.
  adminKeys = config.users.users.root.openssh.authorizedKeys.keys;
  # hermes-desktop on the dave machines dials dave-hermes and joe over ssh
  # with a shared restricted key (../../modules/nixos/hermes-desktop.nix,
  # hyperhermes' desktop module and its clan var hermes-desktop-ssh; dave.nix
  # imports it here too). Its bootstrap needs
  # command execution plus one loopback -L forward to the port
  # `hermes serve --port 0` picks, nothing else: no pty, no agent/X11
  # forwarding.
  desktopKey = ''restrict,port-forwarding,permitopen="127.0.0.1:*" ${
    config.clan.core.vars.generators.hermes-desktop-ssh.files."key.pub".value
  }'';

  gpuHost = "vit.d";
  gpuSkill = inputs.hyperhermes.lib.mkAgentSkill pkgs {
    name = "gpu-host";
    src = lib.fileset.toSource {
      root = ./hermes-gpu-skill;
      fileset = ./hermes-gpu-skill/SKILL.md;
    };
  };
in
{
  imports = [
    inputs.hyperhermes.nixosModules.core
    inputs.hyperhermes.nixosModules.exposure
    inputs.hyperhermes.nixosModules.sso
    inputs.hyperhermes.nixosModules.dashboards
    inputs.hyperhermes.nixosModules.clan
    ./hermes-inference.nix
    inputs.hyperhermes.nixosModules.browser
    ../../modules/nixos/hermes-agents-serve.nix
    inputs.hyperhermes.nixosModules.wallet
    # stefan's account (uid, vault-ro) is shared with vit.
    ../../modules/nixos/users/stefan-vault.nix
    # Agents with `teamclaude.enable` reach Claude through som's TeamClaude.
    inputs.hyperhermes.nixosModules.teamclaude
  ];

  # Claude subscription OAuth for every agent (hermes-claude-auth; the
  # module is imported in ./configuration.nix).
  services.hyperhermes.claudeAuth.enable = true;

  # som's TeamClaude (../../modules/nixos/teamclaude-gateway). Each agent
  # routed through it is a static gateway client of its own name, keyed by
  # its per-machine clan var teamclaude-hermes-<agent> (minted by
  # hyperhermes' clan module), so its usage is booked under the agent's
  # name in `teamclaude status` and dropping the flag revokes it on the
  # next deploy without touching any other client.
  services.hyperhermes.teamclaude.gatewayUrl = "https://teamclaude.davhau.com";
  hyper.teamclaudeGateway.clientKeys = lib.mapAttrs (name: _: "teamclaude-hermes-${name}") (
    lib.filterAttrs (_: a: a.teamclaude.enable) config.services.hyperhermes.agents
  );

  # One shared phoenixd Lightning wallet; every agent below has access.
  services.hyperhermes.wallet.enable = true;

  services.hyperhermes.agents = lib.mkMerge [
    data
    (lib.mapAttrs (_: _: { wallet.enable = true; }) data)
    {
      # Account and description from users/stefan-vault.nix.
      stefan = { };

      pinpox = {
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
        description = "adam - hermes agent, read-only vault consumer";
        sshKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICwDM+8310VQgkMpUu1Oz+ihDBBfCZ/akKMmUIPLgevR adambartnik@Adams-MacBook-Pro-2"
        ];
      };

      j = {
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
        description = "willi - hermes agent";
        sshKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJShRmVEINmRgiXrhpVINJZGw7ZJq3HcCk8kmDM+1B3x reuss@PCBüro"
        ];
      };

      # domi: logs in with the admin keys until he has keys of his own.
      domi = {
        description = "domi - hermes agent";
        sshKeys = adminKeys;
      };

      rti = {
        description = "rti - hermes agent";
        sshKeys = [
          # github.com/rti.keys (fetched 2026-10-02)
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFT8SLyvX8PKh4Gm+hPb8XrSyXSdHnsF6uWDo8G28WUFAAAABHNzaDo= rti"
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIO/KhqU4po6beEkEDFE7ncoLHNwkR+Or+SDXXnZJ/1djAAAABHNzaDo= rti"
          "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIGqhMxHJMNbzSFv9BjPKlpNcQqumDK2q+dvGrhbkJx4gAAAABHNzaDo= rti"
        ];
      };

      chris = {
        description = "chris - hermes agent";
        sshKeys = [
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCyDZ+BWILWGSvZ2ArfmNy50tTuBvFw22eyGFUnmuSCvadHrSPsN67q3iVQ66E5OWqOg4luY4Noq+HkMI0/AG+Y89Fp/2U1B6LETVxV8c70gZXEltiPFhx/BcW737pGMUgHwf22On2Dh9rCZpzPjyMYqF7SJNaoUFEnKntPR97gJhzrGTNggE/Td3piHDcze7WFrFfdlbmMy8COIk2aZ0C7+Wy1D1DE06z54yIZIaelBWJrujeqxP09yDiRlSNEZgNVu/AyzsGoQFwUP9nhjG7PEhvQrWAmlQDxPJRIahLxrrBEl0QOnnAup1gf9OUuxb39WDzN6ejJy3GkcwiAfhfr chris"
        ];
      };

      b3x = {
        description = "b3x - hermes agent";
        sshKeys = [
          # github.com/theanxy.keys (fetched 2026-10-19)
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL98qbBMVca+vmDMSGYTIQVqncMSTrJZlMLXL430UFaJ theanxy"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4W5V2wnXVKvbablE7CM4soDYfdqA7DUbB/04VzrN1r theanxy"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAlGX2PY0MKopFzB280bqIXo7SpNKntS0aLbWgLivCKJ wojtek@wojtek14-2.local"
        ];
      };

      # egg (fabien, github.com/allouis).
      egg = {
        sshKeys = [
          # github.com/allouis.keys (fetched 2026-09-09)
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBcx+vaa7+HgTcP0tpFpgs4SpzoViy8/fERFL6YWBfb0 allouis"
        ];
      };

      # dave's agent, in its OWN account, not the dave login: the agent is
      # untrusted and native mode gives it everything the owning uid has.
      dave-hermes = {
        description = "dave's hermes agent";
        sshKeys = adminKeys ++ [ desktopKey ];
        # Claude through the TeamClaude gateway, not a login of its own.
        teamclaude.enable = true;
      };

      # joe: dave's former amy microVM agent (hermes-grmpf), its state and
      # workspace copied over when amy's microVM was retired. Untrusted like
      # dave-hermes, so its own account; dave signs in to its dashboard.
      joe = {
        description = "joe - dave's hermes agent (ex amy microVM)";
        sshKeys = adminKeys ++ [ desktopKey ];
      };

      # momentum: OpenRouter brain, and a Telegram bot in ONE group chat where
      # several allow-listed people prompt it (connected on its dashboard).
      # Identity (uid 1100, vault-ro) in ../../modules/nixos/vault-ids.nix;
      # logs in with the admin keys until the consumer has one of their own.
      momentum = {
        sshKeys = adminKeys;
        openrouter = true;
        # In the room the bot answers only when addressed (@mention, reply,
        # or a wake word of its TELEGRAM_MENTION_PATTERNS).
        environment.TELEGRAM_REQUIRE_MENTION = "true";
      };
    }
  ];

  users.users = lib.mkMerge [
    # vault readers, as every login on the wg-vault clients.
    (lib.mapAttrs (_: _: { extraGroups = [ "vault-ro" ]; }) data)
    {
      # The daily Open LLM brief cron job (moved from amy's microVM) scans
      # its blog feeds with blogwatcher-cli; the feed db sits in the
      # account home.
      dave-hermes.packages = [ (pkgs.callPackage ../../pkgs/blogwatcher-cli { }) ];
    }
  ];

  # Every agent's dashboard, signed in through the clan's pocket-id: the
  # inventory declares exactly the clients sso.oidcClients lists (from the
  # same ./hermes-dashboards.nix), and their secrets come from there. The
  # exposure (domain, DNS, ACME) is in ./configuration.nix.
  services.hyperhermes.sso = {
    enable = true;
    inherit (config.hyper.oidc) issuer;
    accounts = lib.mapAttrs (name: _: name) data // dashboards.accounts;
    frontDoor.host = dashboards.frontDoor;
    clients = lib.mapAttrs (id: _: {
      secretFile = toString config.hyper.oidc.clients.${id}.secretFile;
    }) config.services.hyperhermes.sso.oidcClients;
  };
  services.hyperhermes.dashboards.enable = true;

  # ssh.nix sets ControlPath ~/.ssh/control/%C fleet-wide; without the
  # directory every ssh fails. hermes runs with HOME = the account home, so
  # the login home is the only one.
  systemd.tmpfiles.rules = lib.concatLists (
    lib.mapAttrsToList (
      name: _:
      let
        home = config.users.users.${name}.home;
      in
      [
        "d ${home}/.ssh 0700 ${name} users -"
        "d ${home}/.ssh/control 0700 ${name} users -"
      ]
    ) data
  );

  # GPU jobs on vit, each agent as its own user with its own key.
  services.hyperhermes.sshKeyHosts = [ gpuHost ];
  # Every harness, not only hermes: spaces links it into each user's
  # skill roots (pi, omp, claude-code) and hermes reads it as a root.
  spaces.agentHarnesses.skills = [ gpuSkill ];
  services.hyperhermes.skillDirs = [ "${gpuSkill}/share/skills" ];

  # The agents' private /tmp, as in their own sessions
  # (../../modules/nixos/per-user-tmp).
  services.hyperhermes.perUserTmp = config.hyper.perUserTmp.enable;

  services.hyperhermes.browser = {
    enable = true;
    # browser_solve_captcha's model: CaptchaKraken on vit
    # (../../modules/nixos/captchakraken-server.nix, which admits som's
    # yggdrasil address). The agents' uids leave through Mullvad, whose kill
    # switch passes yggdrasil (200::/7).
    captchaSolver.baseUrl = "http://vit.d:8096/v1";
    # read_file's scanned-PDF OCR and the agents' `ocr` CLI: Typhoon OCR on
    # vit (../../modules/nixos/ocr-server), same yggdrasil path and
    # admission as the captcha model.
    ocr.baseUrl = "http://vit.d:8098";
  };
  # spaces' microVM module and its slirp-facing SearXNG stay off: spaces
  # would otherwise give every normal user (dave, agent, hsjobeki,
  # nixremote, ...) a hermes microVM, and the browser module runs its own
  # loopback SearXNG.
  services.hermes-microvm.enable = false;
  services.spaces-searxng.enable = false;

  # Host-wide (merged into every agent's config.yaml): one shared session per
  # group chat. By default hermes keys a group session per sender, so
  # momentum's room members would talk to separate agents and a /model
  # override would bind only to the issuer's lane. Both flags must agree: the
  # adapter reads its own copy and the gateway drops routed events whose key
  # disagrees. The other agents are DM bots or dashboard/SSH only, so the
  # flags change nothing for them.
  services.hyperhermes.settings = {
    group_sessions_per_user = false;
    gateway.platforms.telegram.extra.group_sessions_per_user = false;
  };
}
