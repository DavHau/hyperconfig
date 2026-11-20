# GPU host for som's hermes agents: one account per agent, same uid as
# there, reachable only with the agent's own key. Names and uids come from
# ../../machines/som/hermes-agents-data.nix (except `gpu = false`), the
# public keys from som's clan vars (hermes-agent-ssh-<agent>,
# hyperhermes.nixosModules.clan), so the list lives in one place and this
# host never evaluates som.
#
# Per account: reader on /vault/parquet (`vault-ro`, unless the agent's data
# entry says `vault = false`), linger (detached
# jobs survive the ssh session), bash, and a writable python venv at
# ~/.venv over a CUDA python set (torch etc.),
# first on PATH in login shells. The venv is --system-site-packages, so it
# only holds what the agent pip-installs on top.
#
# Network: the agents reach vit with plain ssh sessions only (`ssh vit.d
# <cmd>`, rsync; the gpu-host and tv-camera skills, nothing uses -L/-R/-D),
# so no agent account gets any sshd forwarding (TCP, unix sockets, X11,
# agent, tunnels; stefan's, also Stefan's own login, excepted). An agent marked `lan = false` in the data file also gets
# the same uid guard as on som (./zt-eu-lan-guard, `noLan`): its jobs here
# reach the internet and vit's own addresses (its GPU work is local), no
# LAN, yggdrasil or retiolum; replies to som's ssh are established traffic.
# vit's nix-daemon builds for no agent (trusted-users root, dave, wheel;
# remote building is som's), so no build user carries their traffic.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agentsHost = "som";
  # All but those marked `gpu = false`.
  agents = lib.filterAttrs (_: a: a.gpu or true) (import ../../machines/som/hermes-agents-data.nix);
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
      # vit's RTX 5080 only (compute 12.0): one arch instead of nixpkgs'
      # default list, a fraction of nvcc's time and /build size.
      cudaCapabilities = [ "12.0" ];
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
  imports = [
    ./vault-ids.nix
    ./zt-eu-lan-guard
  ];

  hyper.ztEuLanGuard.noLan.users = lib.attrNames (lib.filterAttrs (_: a: !(a.lan or true)) agents);

  # Every agent-only account: no forwarding of any kind (the noLan users
  # get the same from the guard as well). stefan's is also Stefan's own
  # login (./users/stefan-vault.nix, his keys), left as it was.
  services.openssh.extraConfig = lib.mkAfter ''
    Match User ${lib.concatStringsSep "," (lib.attrNames (removeAttrs agents [ "stefan" ]))}
      DisableForwarding yes
      PermitTunnel no
      PermitListen none
      PermitOpen none
    Match all
  '';

  users.users = lib.mapAttrs (name: a: {
    isNormalUser = true;
    inherit (a) uid;
    extraGroups = lib.optional (a.vault or true) "vault-ro";
    shell = pkgs.bash;
    linger = true;
    openssh.authorizedKeys.keys = [ (publicKeyOf name) ];
  }) agents;

  systemd.services = lib.mkMerge (lib.mapAttrsToList (name: _: (venvOf name).services) agents);

  environment.extraInit = lib.concatStrings (
    lib.mapAttrsToList (name: a: ''
      if [ "$(${pkgs.coreutils}/bin/id -u)" = "${toString a.uid}" ]; then
        export PATH="${(venvOf name).venv}/bin:$PATH"
      fi
    '') agents
  );

  # Standalone executables from pip wheels.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = pythonVenv.nixLdLibraries;
}
