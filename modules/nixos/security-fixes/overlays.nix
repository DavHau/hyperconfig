# Package overlays of the unattended security jobs (../security-fixes.nix
# applies them on every machine): version overrides and upstream patches
# (./<name>.patch) for a CVE, nothing else. A list of overlays:
#
#   [
#     (final: prev: {
#       foo = prev.foo.overrideAttrs (o: {
#         patches = (o.patches or [ ]) ++ [ ./CVE-2026-12345.patch ];
#       });
#     })
#   ]
[ ]
