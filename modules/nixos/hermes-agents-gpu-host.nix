# GPU host for som's hermes agents: one account per agent, same uid as
# there, reachable only with the agent's own key. Names and uids come from
# ../../machines/som/hermes-agents-data.nix, the public keys from som's clan
# vars (hermes-agent-ssh-<agent>, hyperhermes.nixosModules.clan), so the
# list lives in one place and this host never evaluates som.
#
# Per account: reader on /vault/parquet (`vault-ro`), linger (detached
# jobs survive the ssh session), bash, and a writable python venv at
# ~/.venv over a CUDA python set (torch etc. from cache.nixos-cuda.org),
# first on PATH in login shells. The venv is --system-site-packages, so it
# only holds what the agent pip-installs on top.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agentsHost = "som";
  agents = import ../../machines/som/hermes-agents-data.nix;
  publicKeyOf =
    name:
    inputs.clan-core.clanLib.getPublicValue {
      flake = config.clan.core.settings.directory;
      machine = agentsHost;
      generator = inputs.hyperhermes.lib.clan.agentSshGenerator name;
      file = "key.pub";
    };

  pkgsCuda = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (pkgs) overlays;
    config = pkgs.config // {
      allowUnfree = true;
      cudaSupport = true;
    };
  };
  pythonVenv = inputs.hyperhermes.lib.pythonVenv pkgs;
  venvOf =
    name:
    pythonVenv.mkUnit {
      suffix = "-${name}";
      user = name;
      group = "users";
      stateDir = "/home/${name}";
      python = pkgsCuda.python3;
      # The agents' python set on som, built against CUDA here.
      packages = inputs.hyperhermes.lib.pythonPackages;
    };
in
{
  imports = [ ./vault-ids.nix ];

  users.users = lib.mapAttrs (name: a: {
    isNormalUser = true;
    inherit (a) uid;
    extraGroups = [ "vault-ro" ];
    shell = pkgs.bash;
    linger = true;
    openssh.authorizedKeys.keys = [ (publicKeyOf name) ];
  }) agents;

  systemd.services = lib.mkMerge (lib.mapAttrsToList (name: _: (venvOf name).services) agents);

  environment.extraInit = lib.concatStrings (
    lib.mapAttrsToList (name: a: ''
      if [ "$(${pkgs.coreutils}/bin/id -u)" = "${toString a.uid}" ]; then
        export PATH="${(venvOf name).venv}/bin:$PATH"
        export LD_LIBRARY_PATH="${pythonVenv.wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      fi
    '') agents
  );

  # Standalone executables from pip wheels.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = pythonVenv.nixLdLibraries;
}
