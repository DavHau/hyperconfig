# phoenixd 0.9.3 segfaults in ld.so (dl_main) before main: autoPatchelfHook
# runs patchelf 0.19.2 as --set-interpreter, then --set-rpath, and 0.19.2
# then lays out a read-only LOAD segment over the one holding .dynamic, so
# ld.so faults writing DT_DEBUG (https://github.com/NixOS/patchelf/issues/674,
# tracking https://github.com/NixOS/nixpkgs/issues/577387). The upstream fix
# (https://github.com/NixOS/patchelf/pull/672) is merged but unreleased.
# Same workaround nixpkgs applies to other autoPatchelfHook users (rgp,
# cudaPackages): patch with patchelf 0.15.2. The bug is in every release
# from 0.18 on (0.18.0 to 0.19.x), so the workaround stays for any
# pkgs.patchelf >= 0.18; nixpkgs-unstable reverted patchelf to 0.15.2 (by
# 2026-11-12), where plain pkgs.phoenixd works. Once the fleet's nixpkgs
# has a patchelf below 0.18 or one with #672 released, default
# services.hyperhermes.wallet.package to pkgs.phoenixd and delete this file.
pkgs:
if pkgs.lib.versionOlder pkgs.patchelf.version "0.18" then
  pkgs.phoenixd
else
  pkgs.phoenixd.overrideAttrs (old: {
    nativeBuildInputs = [
      (pkgs.patchelf.overrideAttrs (
        finalAttrs: _: {
          version = "0.15.2";
          src = pkgs.fetchurl {
            url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
            hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
          };
        }
      ))
    ]
    ++ old.nativeBuildInputs;
  })
