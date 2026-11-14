# Links libdrm to /opt/amdgpu, where ROCm/amdgpu userspace tools look for
# their ids file (amy, som).
{config, lib, pkgs, ...}: {
  systemd.tmpfiles.rules = [
    "L+ /opt/amdgpu - - - - ${pkgs.libdrm}"
  ];
}
