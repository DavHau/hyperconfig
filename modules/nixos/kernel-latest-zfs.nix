/*
  Use the newest kernel series that the configured ZFS package supports.

  Scans pkgs.linuxKernel.packages.linux_<major>_<minor> (EOL series are
  throwing aliases; tryEval skips them), drops series whose ZFS kernel module
  is marked broken, and picks the highest kernel version. When a new kernel
  series lands before ZFS supports it, this stays on the previous one instead
  of failing the build.
*/
{ config, lib, kernelPkgs, ... }:
let
  zfsModuleAttr = config.boot.zfs.package.kernelModuleAttribute;

  zfsCompatible = lib.filterAttrs
    (name: kernelPackages:
      let
        usable = builtins.tryEval kernelPackages;
        broken = builtins.tryEval kernelPackages.${zfsModuleAttr}.meta.broken;
      in
      builtins.match "linux_[0-9]+_[0-9]+" name != null
      && usable.success
      && usable.value ? ${zfsModuleAttr}
      && broken.success
      && !broken.value)
    kernelPkgs.linuxKernel.packages;

  latest = lib.last (lib.sort
    (a: b: lib.versionOlder a.kernel.version b.kernel.version)
    (builtins.attrValues zfsCompatible));
in
{
  boot.kernelPackages = latest;
}
