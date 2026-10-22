# Kernels and their module sets (zfs, nvidia, ...) from inputs.nixpkgs-kernel
# instead of the fleet nixpkgs: PwnEscape (CVE-2026-99999) is fixed in
# 6.18.57 / 7.2.11, the fleet nixpkgs has 6.18.54 / 7.2.8. Only
# boot.kernelPackages moves; an overlay replacing pkgs.linuxPackages would
# rebuild everything that depends on its userspace tools (qemu, ...).
# Out-of-tree modules build with the kernel's own stdenv (linuxPackagesFor).
# Same nixpkgs config as the machine, so unfree modules (nvidia) evaluate.
# ./kernel-latest-zfs.nix picks its series from kernelPkgs as well.
# Native builds only: cross machines (cm-pi) keep their own kernel. Passing
# crossSystem even when equal to the build platform makes nvidia's 32-bit
# libs (pkgsi686Linux) a cross toolchain built from source.
#
# Drop this module (and the input) once the fleet nixpkgs has the fixes.
{ config, lib, pkgs, inputs, ... }:
let
  native = pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform;
  kernelPkgs = import inputs.nixpkgs-kernel {
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (config.nixpkgs) config;
  };
in
{
  _module.args.kernelPkgs = kernelPkgs;
  boot.kernelPackages = lib.mkIf native (lib.mkDefault kernelPkgs.linuxPackages);
}
