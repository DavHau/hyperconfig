# Route two Anthropic *subscription* (OAuth) accounts to different omp model
# roles on the same host.
#
# Why this exists / why it is this shape
# --------------------------------------
# omp treats `anthropic` as ONE provider. Logging two OAuth accounts into a
# single agent.db makes omp auto-rank/rotate between them — there is no config
# knob to pin "role X -> account A, role Y -> account B" (see
# packages/ai/src/auth-storage.ts ranking). Subagents also run in-process
# (packages/coding-agent/src/task/executor.ts), sharing the parent's
# AuthStorage, so a per-subagent config-dir trick cannot split accounts either.
#
# The only deterministic per-account routing omp supports is giving each
# account its OWN provider id in models.yml. For OAuth subscription accounts
# that requires the auth-gateway path, because:
#   * a custom models.yml provider cannot use stored OAuth and never refreshes
#     the token, and
#   * a raw OAuth bearer sent straight to api.anthropic.com is rejected without
#     the Claude-Code system-prompt/header injection that only the gateway
#     applies (packages/ai/src/auth-gateway/server.ts deliberately removed its
#     passthrough fast-path for exactly this reason).
#
# So per account we run an `omp auth-broker` (holds exactly one account's
# credential -> ranking is trivially deterministic) plus an `omp auth-gateway`
# (a broker client that reshapes+dispatches with that one OAuth credential).
# Each broker/gateway pair runs under its own OMP_PROFILE so their agent.db and
# token files live in ~/.omp/profiles/<profile>/ and never collide. pi.nix then
# defines one `anthropic-messages` custom provider per gateway and pins the
# model roles (default -> main account, task -> sub account).
#
# The models.yml wiring (custom providers + modelRoles) lives in pi.nix, which
# reads the option values declared here.
#
# ONE-TIME MANUAL SETUP (unavoidable — OAuth is interactive):
#   Run these once per host, as the interactive user, after the services exist.
#   The two logins must be sequential — both use OAuth callback port 54545.
#     OMP_PROFILE=acct-main omp auth-broker login anthropic   # log in account 1
#     OMP_PROFILE=acct-sub  omp auth-broker login anthropic   # log in account 2
#     systemctl --user restart omp-broker-main omp-broker-sub
#   (Brokers read agent.db at startup; restart so they pick up the new login.)
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.services.omp-dual-anthropic;
  sys = pkgs.stdenv.hostPlatform.system;

  accountModule = lib.types.submodule ({ ... }: {
    options = {
      profile = lib.mkOption {
        type = lib.types.str;
        description = "OMP_PROFILE name isolating this account's broker/gateway state under ~/.omp/profiles/<profile>/.";
      };
      brokerPort = lib.mkOption {
        type = lib.types.port;
        description = "Loopback port for this account's `omp auth-broker serve`.";
      };
      gatewayPort = lib.mkOption {
        type = lib.types.port;
        description = "Loopback port for this account's `omp auth-gateway serve`. pi.nix points a custom provider baseUrl here.";
      };
      providerId = lib.mkOption {
        type = lib.types.str;
        description = "models.yml provider id backed by this account's gateway.";
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = "Bundled Anthropic model id served under this provider (must match a catalog id, e.g. claude-fable-5).";
      };
    };
  });

  mkServices = key: acct: {
    "omp-broker-${key}" = {
      description = "omp auth-broker for Anthropic account '${key}' (profile ${acct.profile})";
      wantedBy = [ "default.target" ];
      environment.OMP_PROFILE = acct.profile;
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/omp auth-broker serve --bind=127.0.0.1:${toString acct.brokerPort}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    "omp-gateway-${key}" = {
      description = "omp auth-gateway for Anthropic account '${key}' (profile ${acct.profile})";
      wantedBy = [ "default.target" ];
      after = [ "omp-broker-${key}.service" ];
      wants = [ "omp-broker-${key}.service" ];
      # Same OMP_PROFILE as the broker => the gateway auto-discovers the broker
      # bearer at ~/.omp/profiles/<profile>/auth-broker.token. Until the broker
      # has written that file (and is answering), `auth-gateway serve` errors
      # out; Restart=on-failure retries until the pair converges.
      environment = {
        OMP_PROFILE = acct.profile;
        OMP_AUTH_BROKER_URL = "http://127.0.0.1:${toString acct.brokerPort}";
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/omp auth-gateway serve --bind=127.0.0.1:${toString acct.gatewayPort}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
in {
  options.services.omp-dual-anthropic = {
    enable = lib.mkEnableOption "per-account omp auth broker+gateway pair for routing two Anthropic subscription accounts to different model roles" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.llm-agents.packages.${sys}.omp;
      defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.omp";
      description = "omp package providing the `auth-broker` / `auth-gateway` subcommands.";
    };

    mainAccount = lib.mkOption {
      type = accountModule;
      default = {
        profile = "acct-main";
        brokerPort = 8765;
        gatewayPort = 4001;
        providerId = "anthropic-main";
        model = "claude-fable-5";
      };
      description = "Account driving the main agent loop (`default` model role).";
    };

    subAccount = lib.mkOption {
      type = accountModule;
      default = {
        profile = "acct-sub";
        brokerPort = 8766;
        gatewayPort = 4002;
        providerId = "anthropic-sub";
        model = "claude-opus-4-8";
      };
      description = "Account driving subagents (`task` model role).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services =
      (mkServices "main" cfg.mainAccount) // (mkServices "sub" cfg.subAccount);
  };
}
