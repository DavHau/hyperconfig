{ ... }:
{
  environment.shellAliases = {
    dco = "sudo docker-compose";
    # docker = "sudo docker";
    arion = "sudo arion";
    ssh = "env TERM=xterm-color ssh";
    nix-buildr = ''nix-build --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    nixr = ''nix --builders "ssh://root@168.119.226.152 x86_64-linux,aarch64-linux - 100 1 big-parallel,benchmark"'';
    mkcd = ''bash -c 'dir=$1 && mkdir -p $dir && cd $dir' '';
    lg = ''lazygit'';
    nixl = ''nix --builders "" --substituters "https://cache.nixos.org"'';
  };
}
