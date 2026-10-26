# One shared Bitcoin/Lightning wallet for the agents that opt in
# (services.hyperhermes.agents.<name>.wallet.enable): phoenixd, ACINQ's
# headless Phoenix node. It needs no bitcoind and no chain sync (Electrum
# servers for chain data, the ACINQ LSP for channels/liquidity) and keeps
# the keys on this host.
#
# Access is all-or-nothing and shared on purpose (small, capped float):
# every opted-in agent account is in the `lightning-wallet` group, which
# can read the full-access API password. Other local users cannot. The API
# listens on loopback only. Opted-in agents get the `lnwallet` CLI on
# their PATH and the lightning-wallet skill.
#
# Secrets (runtime paths, never in the store; nixosModules.clan fills both
# from the clan vars generators phoenixd-seed and phoenixd-api):
#   - seedFile: the 12-word BIP39 seed, readable by phoenixd only. Back it
#     up. The same seed must never run in a second phoenix instance.
#   - apiConfigFile: `http-password=<hex>` in phoenix.conf syntax, owner
#     phoenixd, group lightning-wallet, 0440. `lnwallet` points
#     phoenix-cli's PHOENIX_DATADIR at its directory, so the password never
#     appears on a command line; hence the file name must be phoenix.conf.
#
# Liquidity: phoenixd's default (--auto-liquidity 2m) buys 2M sat of extra
# inbound liquidity whenever a receive needs it: 1,000 sat channel fee + 1%
# of 2M sat + mining fee (~21.4k sat measured on a real host, 2026-10), a
# large share of a small float. `autoLiquidity` defaults to "off": a
# Lightning receive that does not fit the channel then buys exactly its own
# amount (lightning-kmp IncomingPaymentHandler), i.e. 1,000 sat + 1% +
# mining fee, which is how the wallet is funded: pay a `createinvoice`
# invoice. "off" also disables swap-ins (no funding rate exists for 0 sat),
# so on-chain deposits to `getswapinaddress` are NOT spliced into the
# channel. `--max-fee-credit=off` rejects payments too small to cover that
# fee instead of keeping them as non-refundable fee credit. Fees for an
# amount: `lnwallet estimateliquidityfees --amountSat N`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes.wallet;
  agents = config.services.hyperhermes.agents;
  walletAgents = lib.filterAttrs (_: a: a.wallet.enable) agents;
  port = 9740;
  stateDir = "/var/lib/phoenixd";
  inStore = path: lib.hasPrefix builtins.storeDir (toString path);

  lnwallet = pkgs.writeShellScriptBin "lnwallet" ''
    export PHOENIX_DATADIR=${builtins.dirOf cfg.apiConfigFile}
    exec ${cfg.package}/bin/phoenix-cli --http-bind-port=${toString port} "$@"
  '';

  skill = import ../../lib/agent-skill.nix pkgs {
    name = "lightning-wallet";
    src = lib.fileset.toSource {
      root = ./skill;
      fileset = ./skill/SKILL.md;
    };
  };
in
{
  options.services.hyperhermes = {
    wallet = {
      enable = lib.mkEnableOption "the shared phoenixd Lightning wallet for the agents that opt in";
      package = lib.mkOption {
        type = lib.types.package;
        default = import ./phoenixd.nix pkgs;
        defaultText = lib.literalMD "pkgs.phoenixd, patched with patchelf 0.15.2 (./phoenixd.nix)";
        description = "The phoenixd package (phoenixd and phoenix-cli).";
      };
      seedFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Runtime path of the 12-word BIP39 seed, readable by the phoenixd user only.";
      };
      apiConfigFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Runtime path of a file named phoenix.conf holding
          `http-password=<secret>`, owner phoenixd, group lightning-wallet,
          mode 0440. The agents' `lnwallet` reads it from its directory.
        '';
      };
      autoLiquidity = lib.mkOption {
        type = lib.types.enum [
          "off"
          "2m"
          "5m"
          "10m"
        ];
        default = "off";
        description = "phoenixd --auto-liquidity: inbound liquidity bought when a receive needs a channel.";
      };
      maxMiningFee = lib.mkOption {
        type = lib.types.ints.between 5000 200000;
        default = 5000;
        description = "phoenixd --max-mining-fee in sat: cap on the mining fee of any on-chain operation.";
      };
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options.wallet.enable = lib.mkEnableOption ''
              full access to the shared Lightning wallet
              (services.hyperhermes.wallet): the `lnwallet` CLI, the
              lightning-wallet skill and the API password'';
            config = lib.mkIf config.wallet.enable {
              extraPackages = [ lnwallet ];
              skillDirs = [ "${skill}/share/skills" ];
            };
          }
        )
      );
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (name: _: {
        assertion = cfg.enable;
        message = "services.hyperhermes.agents.${name}.wallet.enable needs services.hyperhermes.wallet.enable.";
      }) walletAgents;
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.seedFile != null && cfg.apiConfigFile != null;
          message = "services.hyperhermes.wallet: set seedFile and apiConfigFile (nixosModules.clan does on a clan machine).";
        }
        {
          assertion =
            !lib.any inStore (
              lib.filter (p: p != null) [
                cfg.seedFile
                cfg.apiConfigFile
              ]
            );
          message = "services.hyperhermes.wallet: seedFile and apiConfigFile must be runtime paths outside the Nix store; the store is world-readable.";
        }
        {
          assertion = cfg.apiConfigFile == null || baseNameOf cfg.apiConfigFile == "phoenix.conf";
          message = "services.hyperhermes.wallet.apiConfigFile must be named phoenix.conf: lnwallet reads it as phoenix-cli's data directory.";
        }
      ];

      users.groups.lightning-wallet = { };
      users.groups.phoenixd = { };
      users.users = {
        phoenixd = {
          isSystemUser = true;
          group = "phoenixd";
          extraGroups = [ "lightning-wallet" ];
          home = stateDir;
        };
      }
      // lib.mapAttrs (_: _: { extraGroups = [ "lightning-wallet" ]; }) walletAgents;

      systemd.services.phoenixd = {
        description = "phoenixd shared Lightning wallet";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment.PHOENIX_DATADIR = stateDir;
        serviceConfig = {
          User = "phoenixd";
          Group = "phoenixd";
          StateDirectory = "phoenixd";
          StateDirectoryMode = "0700";
          UMask = "0077";
          # phoenixd appends generated secrets (limited-access password,
          # webhook secret) to its conf; rewriting it on every start keeps
          # the full-access password apiConfigFile's.
          ExecStartPre = "${pkgs.coreutils}/bin/install -m 0600 ${cfg.apiConfigFile} ${stateDir}/phoenix.conf";
          ExecStart = lib.escapeShellArgs [
            "${cfg.package}/bin/phoenixd"
            "--agree-to-terms-of-service"
            "--seed-path=${cfg.seedFile}"
            "--http-bind-ip=127.0.0.1"
            "--http-bind-port=${toString port}"
            "--auto-liquidity=${cfg.autoLiquidity}"
            "--max-mining-fee=${toString cfg.maxMiningFee}"
            "--max-fee-credit=off"
            "--silent"
          ];
          Restart = "on-failure";
          RestartSec = 10;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
        };
      };
    })
  ];
}
