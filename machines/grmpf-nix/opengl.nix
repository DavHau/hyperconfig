{config, ib, pkgs, ...}:
let
  rocm = pkgs.rocmPackages.meta;
in
{
  # Install OpenCL packages
  environment.systemPackages = [
    rocm.rocm-opencl-runtime
    pkgs.ocl-icd
    pkgs.clinfo
  ];

  hardware.graphics = {
    enable = true;
    extraPackages = [
      rocm.rocm-opencl-runtime
    ];
  };
}
