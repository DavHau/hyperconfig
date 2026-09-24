# GPU host for the native hermes agents of `agentsHost` (som): one account
# per agent, same uid as there, reachable only with the agent's own key
# (hyper.hermesAgentsGpuHost, ./hermes-agents.nix). The agents' names,
# uids and keys are read from that machine's config, so the list lives in
# one place.
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
  host = inputs.self.nixosConfigurations.${agentsHost}.config;
  agents = lib.attrNames host.hyper.hermesAgents;

  pkgsCuda = import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (pkgs) overlays;
    config = pkgs.config // {
      allowUnfree = true;
      cudaSupport = true;
    };
  };
  pythonVenv = import "${inputs.spaces}/modules/nixos/hermes/python-venv.nix" { inherit lib pkgs; };
  venvOf =
    name:
    pythonVenv.mkUnit {
      suffix = "-${name}";
      user = name;
      group = "users";
      stateDir = "/home/${name}";
      python = pkgsCuda.python3;
      packages = config.services.hermes-microvm.pythonPackages;
    };
in
{
  imports = [ ./vault-ids.nix ];

  users.users = lib.genAttrs agents (name: {
    isNormalUser = true;
    inherit (host.users.users.${name}) uid;
    extraGroups = [ "vault-ro" ];
    shell = pkgs.bash;
    linger = true;
    openssh.authorizedKeys.keys = [
      host.clan.core.vars.generators."hermes-agent-ssh-${name}".files."key.pub".value
    ];
  });

  systemd.services = lib.mkMerge (map (name: (venvOf name).services) agents);

  environment.extraInit = lib.concatMapStrings (name: ''
    if [ "$(${pkgs.coreutils}/bin/id -u)" = "${toString host.users.users.${name}.uid}" ]; then
      export PATH="${(venvOf name).venv}/bin:$PATH"
      export LD_LIBRARY_PATH="${pythonVenv.wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  '') agents;

  # Standalone executables from pip wheels.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = pythonVenv.nixLdLibraries;
}
