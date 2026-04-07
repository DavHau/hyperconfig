{config, lib, pkgs, ...}: {
  systemd.tmpfiles.rules = [
    "L+ /opt/amdgpu - - - - ${pkgs.libdrm}"
  ];
}
