{config, ib, pkgs, ...}: {
  # Install OpenCL packages
  environment.systemPackages = with pkgs; [
    rocm-opencl-runtime
    rocm-opencl-icd
    ocl-icd
    clinfo
  ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      rocm-opencl-runtime
      rocm-opencl-icd
      # intel-compute-runtime
    ];
  };
}
