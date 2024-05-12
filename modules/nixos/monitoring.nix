{inputs, ...}: {
  imports = [
    inputs.srvos.nixosModules.mixins-telegraf
  ];

  services.zerotierone.joinNetworks = [
    "b15644912e61dbe0"  # monitoring
  ];

  networking.firewall.interfaces."zteb4ckswo".allowedTCPPorts = [ 9273 ];
}
