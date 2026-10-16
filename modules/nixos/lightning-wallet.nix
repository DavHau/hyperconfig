# One shared Bitcoin/Lightning wallet for every native hermes agent
# (hyper.hermesAgents): phoenixd, ACINQ's headless Phoenix node. It needs
# no bitcoind and no chain sync (Electrum servers for chain data, the
# ACINQ LSP for channels/liquidity) and keeps the keys on this host.
#
# Access is all-or-nothing and shared on purpose (small, capped float):
# every agent account is in the `lightning-wallet` group, which can read
# the full-access API password. Other local users cannot. The API listens
# on loopback only.
#
# Secrets (clan vars, generated automatically):
#   - phoenixd-seed/seed: the 12-word BIP39 seed, readable by phoenixd
#     only. Back it up: `clan vars get <machine> phoenixd-seed/seed`.
#     The same seed must never run in a second phoenix instance.
#   - phoenixd-api/phoenix.conf: `http-password=<hex>` in phoenix.conf
#     syntax, so `lnwallet` points phoenix-cli's PHOENIX_DATADIR at the
#     var's directory and the password never appears on a command line.
#
# Liquidity: phoenixd's default (--auto-liquidity 2m) buys 2M sat of extra
# inbound liquidity whenever a receive needs it: 1,000 sat channel fee + 1%
# of 2M sat + mining fee (~21.4k sat measured on som, 2026-10), a large
# share of a small float. `autoLiquidity` defaults to "off": a Lightning
# receive that does not fit the channel then buys exactly its own amount
# (lightning-kmp IncomingPaymentHandler), i.e. 1,000 sat + 1% + mining
# fee, which is how the wallet is funded: pay a `createinvoice` invoice.
# "off" also disables swap-ins (no funding rate exists for 0 sat), so
# on-chain deposits to `getswapinaddress` are NOT spliced into the
# channel. `--max-fee-credit=off` rejects payments too small to cover
# that fee instead of keeping them as non-refundable fee credit. Fees for
# an amount: `lnwallet estimateliquidityfees --amountSat N`.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.hyper.lightningWallet;
  port = 9740;
  stateDir = "/var/lib/phoenixd";
  apiConf = config.clan.core.vars.generators.phoenixd-api.files."phoenix.conf";
  seed = config.clan.core.vars.generators.phoenixd-seed.files.seed;

  lnwallet = pkgs.writeShellScriptBin "lnwallet" ''
    export PHOENIX_DATADIR=${builtins.dirOf apiConf.path}
    exec ${pkgs.phoenixd}/bin/phoenix-cli --http-bind-port=${toString port} "$@"
  '';

  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "lightning-wallet";
    src = lib.fileset.toSource {
      root = ./lightning-wallet-skill;
      fileset = ./lightning-wallet-skill/SKILL.md;
    };
  };
in
{
  options.hyper.lightningWallet = {
    enable = lib.mkEnableOption "the shared phoenixd Lightning wallet for the native hermes agents";
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

  config = lib.mkIf cfg.enable {
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
    // lib.mapAttrs (_: _: { extraGroups = [ "lightning-wallet" ]; }) config.hyper.hermesAgents;

    clan.core.vars.generators.phoenixd-seed = {
      files.seed = {
        secret = true;
        owner = "phoenixd";
        mode = "0400";
        restartUnits = [ "phoenixd.service" ];
      };
      runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.mnemonic ])) ];
      script = ''
        python3 -c 'import mnemonic; print(mnemonic.Mnemonic("english").generate(128))' > "$out"/seed
      '';
    };

    clan.core.vars.generators.phoenixd-api = {
      files."phoenix.conf" = {
        secret = true;
        owner = "phoenixd";
        group = "lightning-wallet";
        mode = "0440";
        restartUnits = [ "phoenixd.service" ];
      };
      runtimeInputs = [ pkgs.openssl ];
      script = ''
        printf 'http-password=%s\n' "$(openssl rand -hex 32)" > "$out"/phoenix.conf
      '';
    };

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
        # the full-access password the clan var's.
        ExecStartPre = "${pkgs.coreutils}/bin/install -m 0600 ${apiConf.path} ${stateDir}/phoenix.conf";
        ExecStart = lib.escapeShellArgs [
          "${pkgs.phoenixd}/bin/phoenixd"
          "--agree-to-terms-of-service"
          "--seed-path=${seed.path}"
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

    services.hermes-native.extraPackages = [ lnwallet ];
    services.hermes-native.settings.skills.external_dirs = [ "${skill}/share/skills" ];
  };
}
