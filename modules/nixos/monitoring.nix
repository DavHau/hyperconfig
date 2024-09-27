# Every device needs to be added to https://github.com/Mic92/dotfiles/blob/main/machines/eva/modules/telegraf/dave.nix

{inputs, ...}: {
  imports = [
    inputs.srvos.nixosModules.mixins-telegraf
  ];

  services.zerotierone.enable = true;
  services.zerotierone.joinNetworks = [
    "b15644912e61dbe0"  # monitoring
  ];

  networking.firewall.interfaces."zteb4ckswo".allowedTCPPorts = [ 9273 ];
}
