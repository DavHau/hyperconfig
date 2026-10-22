# nvidia-smi, nvidia-powerd and nvidia-cuda-mps-* segfault in ld.so before
# main: patchelf 0.19.2 lays out a broken ELF when one invocation sets both
# interpreter and rpath (https://github.com/NixOS/nixpkgs/issues/576412,
# https://github.com/NixOS/patchelf/issues/674). Backport of the merged
# nixpkgs fix https://github.com/NixOS/nixpkgs/pull/576397: two invocations,
# rpath first. The assertion fails once the fleet nixpkgs carries the fix;
# then delete this module and its import in ./nvidia.nix.
{ config, lib, pkgs, ... }:
let
  stock = config.boot.kernelPackages.nvidiaPackages.stable;
  # mkDerivation turns `builder = ./builder.sh` into bash args; it is last.
  stockBuilder = builtins.readFile (lib.last stock.args);
  single = ''
    patchelf --interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                        --set-rpath $out/lib:$libPath $bin/bin/$i'';
  split = ''
    patchelf --set-rpath "$out/lib:$libPath" "$bin/bin/$i"
                    patchelf --interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" "$bin/bin/$i"'';
  patched = builtins.replaceStrings [ single ] [ split ] stockBuilder;
in
{
  hardware.nvidia.package =
    assert !lib.hasInfix "576412" stockBuilder;
    assert patched != stockBuilder;
    stock.overrideAttrs { builder = pkgs.writeText "nvidia-x11-builder.sh" patched; };
}
