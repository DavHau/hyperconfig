# phoenixd 0.9.3 segfaults in ld.so (dl_main) before main: autoPatchelfHook
# runs patchelf 0.19.2 as --set-interpreter, then --set-rpath, and 0.19.2
# then lays out a read-only LOAD segment over the one holding .dynamic, so
# ld.so faults writing DT_DEBUG (https://github.com/NixOS/patchelf/issues/674,
# tracking https://github.com/NixOS/nixpkgs/issues/577387). The upstream fix
# (https://github.com/NixOS/patchelf/pull/672) is merged but unreleased.
# Same workaround nixpkgs applies to other autoPatchelfHook users (rgp,
# cudaPackages): patch with patchelf 0.15.2. The assertion fails once the
# fleet nixpkgs moves past patchelf 0.19.2; then delete this module and its
# import in ./lightning-wallet.nix.
{
  nixpkgs.overlays = [
    (final: prev: {
      phoenixd =
        assert prev.patchelf.version == "0.19.2";
        prev.phoenixd.overrideAttrs (old: {
          nativeBuildInputs = [
            (prev.patchelf.overrideAttrs (finalAttrs: _: {
              version = "0.15.2";
              src = prev.fetchurl {
                url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
                hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
              };
            }))
          ] ++ old.nativeBuildInputs;
        });
    })
  ];
}
