# noctalia-qs 0.0.12 fails to build against Qt 6.12 ("Meta Types must be
# fully defined" in quickshell-hyprland-ipc): its Hyprland IPC classes are
# opaque pointers to moc. Fixed upstream in quickshell 5d5d4987; noctalia-qs
# (v4 is end-of-life, noctalia-dev/noctalia#4761) has no release with it.
# The assertion fails once nixpkgs moves past 0.0.12: then check whether the
# new release builds and delete this module and the patch.
{ lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      noctalia-qs =
        assert prev.noctalia-qs.version == "0.0.12";
        prev.noctalia-qs.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./noctalia-qs-qt612.patch ];
        });
    })
  ];
}
