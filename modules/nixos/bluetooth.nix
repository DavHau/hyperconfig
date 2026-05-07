{ ... }:
{
  hardware.bluetooth = {
    enable = true;
    # powerOnBoot = true;
    # settings = {
    #   General = {
    #     ControllerMode = "dual";
    #     Experimental = true;
    #   };
    #   Policy.AutoEnable = true;
    # };
  };

  # hack for xbox controller:
  # boot.extraModprobeConfig = ''
  #   options bluetooth disable_ertm=1
  #   options kvm_intel nested=1
  #   options kvm_intel emulate_invalid_guest_state=0
  #   options kvm ignore_msrs=1
  # '';
}
