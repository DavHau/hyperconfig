# Upstream's hermes package (v0.23.0) takes node from pm/lock.json: the
# nodejs.org linux-x64 tarball, made to run by autoPatchelfHook
# (nix/pm-packages.nix). With nixpkgs' patchelf 0.19.2 (also 0.18.0) that
# binary segfaults at start once its RPATH or NEEDED entries change,
# before `node --version` prints anything (the unmodified binary run
# through the same ld.so works; patchelf 0.15.2, upstream's nixpkgs pin,
# works). Every npm build of the package (web, TUI, desktop renderer) then
# dies in npmConfigHook. So the node the package builds and runs with is
# this nixpkgs' nodejs_26 instead; the pinned npm still runs on top of it
# (nix/lib.nix).
#
# The other pm packages (ffmpeg, ripgrep, uv, python) are patched with
# upstream's `patchelfFixed`: pkgs.patchelf plus the patchelf#672 fix, a
# patch written against 0.19.2. The bug is in every release from 0.18 on
# (0.18.0 to 0.19.x), so upstream's patchelfFixed stays for any
# pkgs.patchelf >= 0.18 (should its patch stop applying there, the build
# fails loudly). nixpkgs-unstable reverted patchelf to 0.15.2 (by
# 2026-11-12), which predates the bug and on which the patch does not
# apply; below 0.18 they get plain pkgs.patchelf. Same condition as
# ../modules/wallet/phoenixd.nix. Once the fleet's nixpkgs has a patchelf
# below 0.18 or one with #672 released, drop `plainPatchelf` (and upstream
# will have dropped its patch).
#
# `hermesPackage` is upstream's `packages.<system>.default` (a callPackage
# result); `pkgs` provides nodejs_26 and patchelf.
pkgs: hermesPackage:
let
  inherit (pkgs) lib;
  plainPatchelf =
    drv:
    drv.overrideAttrs (old: {
      nativeBuildInputs = map (
        p: if lib.getName p == "patchelf" then pkgs.patchelf else p
      ) old.nativeBuildInputs;
    });
  pmPatchelf =
    pm: if lib.versionOlder pkgs.patchelf.version "0.18" then lib.mapAttrs (_: plainPatchelf) pm else pm;
in
hermesPackage.override (prev: {
  pmPackages = pmPatchelf prev.pmPackages // {
    node = pkgs.nodejs_26;
  };
})
