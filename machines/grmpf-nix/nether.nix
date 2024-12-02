{inputs, ...}: {
  imports = [
    inputs.nether.nixosModules.hosts
    inputs.nether.nixosModules.zerotier
  ];
}
