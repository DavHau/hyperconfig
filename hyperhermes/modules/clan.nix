# Secrets of hyperhermes from clan vars, for a host in a clan
# (https://clan.lol). This flake does not depend on clan: the importing
# system brings clan-core's NixOS module, and without `clan.core.vars` this
# module does nothing. Each feature's part applies only where that
# feature's module is imported.
#
# Generator and file names are what the clan's vars store holds; renaming
# one orphans the stored secret.
#
# core, per agent the per-machine generator hermes-agent-ssh-<agent>: the
# agent's own ssh key, `key` readable by the agent only, `key.pub` public
# (clanLib.getPublicValue hands it to the hosts that authorize it). Its
# path becomes agents.<agent>.sshKeyFile.
#
# teamclaude, per agent with teamclaude.enable the per-machine generator
# teamclaude-hermes-<agent>: the agent's gateway client key, root-only
# (only the agent unit's LoadCredential reads it), with the
# `sk-ant-oat01-` prefix of a Claude Code OAuth token. Its path becomes
# agents.<agent>.teamclaude.keyFile; the gateway's configuration declares
# the same var as client `<agent>`.
#
# desktop, the shared generator hermes-desktop-ssh: the one restricted
# ssh key every workstation's app dials the agents with, root-only, and
# its public half for the agents' host to authorize. Its path becomes
# desktop.sshKeyFile.
#
# wallet, with services.hyperhermes.wallet on (./wallet): phoenixd-seed
# (`seed`, phoenixd's only; back it up with
# `clan vars get <machine> phoenixd-seed/seed`) and phoenixd-api
# (`phoenix.conf`, the API password, group lightning-wallet) fill its
# seedFile and apiConfigFile.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  # clan.core.vars is a submodule option; its generators live inside.
  hasClan = options ? clan.core.vars;
  # Feature modules this system imports.
  hasCore = options ? services.hyperhermes.package;
  hasTeamclaude = options ? services.hyperhermes.teamclaude;
  hasDesktop = options ? services.hyperhermes.desktop;
  hasWallet = options ? services.hyperhermes.wallet;
  walletOn = hasWallet && cfg.wallet.enable;
  generatorFor = name: "hermes-agent-ssh-${name}";
  teamclaudeGeneratorFor = name: "teamclaude-hermes-${name}";
  generators = config.clan.core.vars.generators;
in
{
  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config = {
            sshKeyFile = lib.mkIf hasClan (
              lib.mkDefault config.clan.core.vars.generators.${generatorFor name}.files.key.path
            );
          }
          // lib.optionalAttrs hasTeamclaude {
            teamclaude.keyFile = lib.mkIf hasClan (
              lib.mkDefault config.clan.core.vars.generators.${teamclaudeGeneratorFor name}.files.key.path
            );
          };
        }
      )
    );
  };

  # optionalAttrs, not mkIf: without clan (or the feature) there is no
  # option to define.
  config = lib.optionalAttrs hasClan (
    lib.mkMerge [
      {
        clan.core.vars.generators = lib.mkMerge [
          (lib.optionalAttrs hasCore (
            lib.mapAttrs' (
              name: _:
              lib.nameValuePair (generatorFor name) {
                files.key = {
                  secret = true;
                  owner = name;
                };
                files."key.pub".secret = false;
                runtimeInputs = [ pkgs.openssh ];
                script = ''
                  ssh-keygen -q -t ed25519 -N "" -C "${name}@${config.networking.hostName}" -f "$out"/key
                '';
              }
            ) cfg.agents
          ))

          (lib.optionalAttrs (hasCore && hasTeamclaude) (
            lib.mapAttrs' (
              name: _:
              lib.nameValuePair (teamclaudeGeneratorFor name) {
                runtimeInputs = [ pkgs.openssl ];
                script = ''
                  printf 'sk-ant-oat01-%s' "$(openssl rand -hex 32)" > "$out/key"
                '';
                files.key.restartUnits = [ "hermes-agent-${name}.service" ];
              }
            ) (lib.filterAttrs (_: a: a.teamclaude.enable) cfg.agents)
          ))

          (lib.optionalAttrs hasDesktop {
            hermes-desktop-ssh = lib.mkIf cfg.desktop.enable {
              share = true;
              files.key = { };
              files."key.pub".secret = false;
              runtimeInputs = [ pkgs.openssh ];
              script = ''
                ssh-keygen -q -t ed25519 -N "" -C hermes-desktop -f "$out"/key
              '';
            };
          })
        ];
      }

      (lib.optionalAttrs hasDesktop {
        services.hyperhermes.desktop.sshKeyFile = lib.mkDefault generators.hermes-desktop-ssh.files.key.path;
      })

      (lib.optionalAttrs hasWallet {
        services.hyperhermes.wallet = lib.mkIf walletOn {
          seedFile = lib.mkDefault generators.phoenixd-seed.files.seed.path;
          apiConfigFile = lib.mkDefault generators.phoenixd-api.files."phoenix.conf".path;
        };

        clan.core.vars.generators = lib.mkIf walletOn {
          phoenixd-seed = {
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

          phoenixd-api = {
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
        };
      })
    ]
  );
}
