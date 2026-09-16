/*
  Fleet-wide `agent` user.

  Every sbox sandbox runs with amy's ~/.ssh/id_ed25519_github1 bound over
  ~/.ssh/id_ed25519 (modules/nixos/sbox.nix), making it the agents' ssh
  identity. This module gives that identity a first-class account on every
  clan machine (wired via the `admin` instance's extraModules in
  modules/flake-parts/nixosConfigurations.nix):

    - `agent` user, key-only login, authorized for the sbox key
    - the private key itself installed at ~agent/.ssh/id_ed25519 (shared
      clan var, prompted once from amy's file), so agent@X can hop to
      agent@Y.d without extra setup

  Host keys verify via the clan sshd instance's cert CA; no known_hosts
  prompts. NOTE: sshd only reads /etc/ssh/authorized_keys.d/%u on hosts
  running the spaces module (see machines/vit/configuration.nix) — the
  declarative key below lands exactly there.
*/
{ config, options, lib, pkgs, ... }:
let
  # amy: ~/.ssh/id_ed25519_github1.pub — the key sbox mounts into sandboxes.
  pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM7ptVA/R16UvtWJD3VfJUWdEL2nzonoFRz2Na6lg+UU agent@amy";
  privKey = config.clan.core.vars.generators.agent-ssh.files."id_ed25519";
  pubFile = pkgs.writeText "agent-id_ed25519.pub" (pubKey + "\n");
in
{
  # p0 inference over omp/afk, same as egg (./egg-hermes.nix): a root
  # oneshot installs a 0400 copy of the shared token at
  # /run/inference-api-key/agent/token, which `p0-api-key` (models.yml
  # apiKey: "!p0-api-key") reads for the calling user
  # (./inference-api-key.nix). That module only rides along dave.nix
  # (amy, vit, som); this file is fleet-wide, so the option is set only
  # where it exists — `lib.mkIf` would still declare the path and fail
  # evaluation on the other hosts.
  config = lib.optionalAttrs (options ? hyper && options.hyper ? inferenceApiKey) {
    hyper.inferenceApiKey.users = [ "agent" ];
  } // {
  users.groups.agent = { };
  users.users.agent = {
    isNormalUser = true;
    group = "agent";
    description = "fleet agent (sbox ssh identity)";
    openssh.authorizedKeys.keys = [ pubKey ];
    # Rootless Docker maps container uids onto this range; task images with
    # uids past 65535 (Windows-built layers, e.g. Terminal-Bench's ensembl-vep
    # image at uid 197609) fail to extract with the 65536 default. Starts
    # above grmpf's auto-allocated ranges.
    subUidRanges = [
      {
        startUid = 200000;
        count = 1000000;
      }
    ];
    subGidRanges = [
      {
        startGid = 200000;
        count = 1000000;
      }
    ];
  };

  clan.core.vars.generators.agent-ssh = {
    share = true;
    prompts."private-key" = {
      description = "agent ssh private key: paste amy's ~/.ssh/id_ed25519_github1";
      type = "multiline";
      persist = true;
    };
    files."id_ed25519" = {
      secret = true;
      owner = "agent";
      group = "agent";
    };
    runtimeInputs = [ pkgs.coreutils ];
    # printf(1) guarantees the trailing newline OpenSSH requires; pasted
    # multiline prompts often lose it.
    script = ''
      printf '%s\n' "$(cat "$prompts"/private-key)" > "$out"/id_ed25519
    '';
  };

  systemd.tmpfiles.rules = [
    "d /home/agent/.ssh 0700 agent agent -"
    # ssh.nix sets ControlPath ~/.ssh/control/%C fleet-wide
    "d /home/agent/.ssh/control 0700 agent agent -"
    "L+ /home/agent/.ssh/id_ed25519 - - - - ${privKey.path}"
    "L+ /home/agent/.ssh/id_ed25519.pub - - - - ${pubFile}"
  ];
  };
}
