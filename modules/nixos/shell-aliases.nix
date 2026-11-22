{ config, lib, ... }:
let
  inherit (config.virtualisation) docker podman;
  dockerOn = docker.enable || docker.rootless.enable;
in
{
  environment.shellAliases = {
    ssh = "env TERM=xterm-color ssh";
    nix-buildr = ''nix-build --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    nixr = ''nix --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    mkcd = ''bash -c 'dir=$1 && mkdir -p $dir && cd $dir' '';
    lg = ''lazygit'';
    nixl = ''nix --builders "" --substituters "https://cache.nixos.org"'';
  };
  # Only where the compose tools are installed (./packages.nix): not amy.
  environment.shellAliases.dco = lib.mkIf dockerOn "docker-compose";
  environment.shellAliases.arion = lib.mkIf (dockerOn || podman.enable) "sudo arion";
}
