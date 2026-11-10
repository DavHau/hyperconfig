/*
  clan-secret-prompt (./clan-secret-prompt.py): the agent asks Dave for a
  clan var's value on a web page instead of in chat, so the value never
  enters the model's context, the session or a log.

  The agent (infra) runs `clan-secret-prompt <machine> <generator> [<file>]`:
  a one-time request in /run/clan-secret-prompt (0700 infra, one 0600 file
  per request: 128-bit id, its own form token, the machine, generator and
  file(s) it is bound to, 15 minutes), printing only its URL,
  <url>/secret/<id>. Dave opens it: the host's nginx lets it through only
  with a valid session of the dashboard's OIDC login (../dashboard.nix) to
  this service, which shows what the value is for (and whether one is set
  already), takes it masked and confirmed, and hands it on stdin to the
  `clan` wrapper (../guest.nix: synced and pushed): `clan vars set`, and for
  a generator asked as a whole `clan vars generate` after it. The agent
  learns only `set`, `expired`, `cancelled` or `error: <reason>`
  (`clan-secret-prompt --wait <id>`).

  Not a boundary against infra itself: infra holds the age identity and can
  read and write every var anyway. What it keeps out is the value's way
  through the chat (the model's context, the session store, the
  provider's logs) and a prompt-injected agent's request going unnoticed
  (the page names the machine, generator and file prominently).

  On the guest's veth address (the host's nginx dials it, ../default.nix
  admits nginx to the port), where the dashboard is published (som). Inside
  the guest only root may dial the port (an owner gate on the output path,
  as hermes' own ports have), and the service answers the host's veth
  address only.

  Generate mode runs the generator through clan, in clan's bwrap sandbox:
  checked to work for infra in som's guest under this unit's hardening
  (user namespaces are allowed there; NoNewPrivileges does not stop bwrap
  without setuid). It refuses a generator that exists already (clan would
  not rerun it): regenerating needs Dave at a terminal.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.infraSpace.secretPrompt;
  stateDir = "/run/clan-secret-prompt";
  home = "/home/infra";
  python = pkgs.python3;
  # what the CLI and the service run: the `clan` wrapper, nix for the
  # generator's definition, git for the flake's state, age for clan
  path = [
    config.infraSpace.clanWrapper
    config.nix.package
    pkgs.git
    pkgs.openssh
    pkgs.age
    pkgs.age-plugin-tpm
    pkgs.coreutils
  ];
  tool = pkgs.writeShellApplication {
    name = "clan-secret-prompt";
    runtimeInputs = path;
    text = ''
      export CLAN_SECRET_PROMPT_DIR=${stateDir}
      export CLAN_SECRET_PROMPT_URL=${lib.escapeShellArg cfg.url}
      export CLAN_SECRET_PROMPT_CLAN=${lib.getExe config.infraSpace.clanWrapper}
      export CLAN_SECRET_PROMPT_STORE=${home}/clan-secrets
      export CLAN_SECRET_PROMPT_FLAKE=${home}/hyperconfig
      exec ${python.interpreter} ${./clan-secret-prompt.py} "$@"
    '';
  };
in
{
  options.infraSpace.secretPrompt = {
    enable = lib.mkEnableOption "clan-secret-prompt: Dave enters clan var values on a page behind the dashboard's login";
    url = lib.mkOption {
      type = lib.types.str;
      description = "The dashboard's public origin; the page is <url>/secret/<id>.";
    };
    listenAddress = lib.mkOption {
      type = lib.types.str;
      description = "The guest's veth address the host's nginx dials.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 9121;
      description = "Port on listenAddress.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ tool ];

    systemd.tmpfiles.settings.clan-secret-prompt.${stateDir}.d = {
      user = "infra";
      group = "infra";
      mode = "0700";
    };

    systemd.services.clan-secret-prompt = {
      description = "Take clan var values from Dave (clan-secret-prompt)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "systemd-tmpfiles-setup.service"
      ];
      inherit path;
      environment = {
        HOME = home;
        CLAN_SECRET_PROMPT_DIR = stateDir;
        CLAN_SECRET_PROMPT_URL = cfg.url;
        CLAN_SECRET_PROMPT_CLAN = lib.getExe config.infraSpace.clanWrapper;
        CLAN_SECRET_PROMPT_STORE = "${home}/clan-secrets";
        # the host's nginx is the only client
        CLAN_SECRET_PROMPT_PEER = config.infraSpace.hostAddress;
        PYTHONDONTWRITEBYTECODE = "1";
        PYTHONUNBUFFERED = "1";
      };
      serviceConfig = {
        User = "infra";
        Group = "infra";
        ExecStart = "${python.interpreter} ${./clan-secret-prompt.py} --serve ${cfg.listenAddress}:${toString cfg.port}";
        Restart = "always";
        UMask = "0077";
        # no core dump of a process holding a value
        LimitCORE = 0;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        # clan's process groups go with the service
        KillMode = "control-group";
      };
    };

    # Inside the guest: the port for root only (the host's nginx comes in
    # through the veth, not this path). Its own chain, rebuilt whenever the
    # firewall flushes the tables, as hyperhermes' hermes-firewall does.
    systemd.services.clan-secret-prompt-firewall = {
      description = "Owner gate on clan-secret-prompt's port inside the guest";
      wantedBy = [ "multi-user.target" ];
      before = [ "clan-secret-prompt.service" ];
      after = [
        "firewall.service"
        "nftables.service"
      ];
      partOf =
        lib.optional config.networking.nftables.enable "nftables.service"
        ++ lib.optional (!config.networking.nftables.enable) "firewall.service";
      path = [ pkgs.iptables ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        iptables -w -N clan-secret-prompt 2>/dev/null || true
        iptables -w -F clan-secret-prompt
        iptables -w -A clan-secret-prompt -p tcp --dport ${toString cfg.port} -m owner --uid-owner 0 -j RETURN
        iptables -w -A clan-secret-prompt -p tcp --dport ${toString cfg.port} -j REJECT --reject-with tcp-reset
        iptables -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j clan-secret-prompt 2>/dev/null \
          || iptables -w -I OUTPUT 1 -o lo -p tcp -m conntrack --ctstate NEW -j clan-secret-prompt
      '';
      preStop = ''
        iptables -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j clan-secret-prompt 2>/dev/null || true
        iptables -w -F clan-secret-prompt 2>/dev/null || true
        iptables -w -X clan-secret-prompt 2>/dev/null || true
      '';
    };
  };
}
