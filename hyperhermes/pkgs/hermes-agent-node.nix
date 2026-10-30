# Upstream's hermes package (v0.22.5) takes node from pm/lock.json: the
# nodejs.org linux-x64 tarball, made to run by autoPatchelfHook
# (nix/pm-packages.nix). The patchelf of our nixpkgs (0.19.2, also
# 0.18.0) breaks that binary: once its RPATH or NEEDED entries change it
# segfaults at start, before `node --version` prints anything (the
# unmodified binary run through the same ld.so works; patchelf 0.15.2,
# upstream's nixpkgs pin, works). Every npm build of the package (web,
# TUI, desktop renderer) then dies in npmConfigHook. So the node the
# package builds and runs with is this nixpkgs' nodejs_26 instead; the
# pinned npm still runs on top of it (nix/lib.nix).
#
# `hermesPackage` is upstream's `packages.<system>.default` (a callPackage
# result); `pkgs` provides nodejs_26.
pkgs: hermesPackage:
hermesPackage.override (prev: {
  pmPackages = prev.pmPackages // {
    node = pkgs.nodejs_26;
  };
})
