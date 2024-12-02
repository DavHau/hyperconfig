{lib, ...}: {
  imports = [
    ./host-module.nix
  ];
  virtualisation.diskSize = 40 * 1024;
  virtualisation.memorySize = 16000;
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "zerotierone"
  ];
}
