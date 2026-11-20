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
[
  # php84 8.4.28 (bam's Nextcloud / phpfpm): CVE-2026-115560,
  # CVE-2026-126714, CVE-2026-129289, CVE-2026-129496, CVE-2026-129291,
  # CVE-2026-129481, CVE-2026-127960, CVE-2026-128064, CVE-2026-128090.
  # Same version/hash as upstream nixpkgs; php84's buildEnv is
  # makeOverridable and passes version/hash on to generic.nix, keeping the
  # default extension set. Drop once nixpkgs php84 >= 8.4.28.
  (final: prev: {
    php84 =
      if prev.lib.versionAtLeast prev.php84.version "8.4.28" then
        prev.php84
      else
        prev.php84.override {
          version = "8.4.28";
          hash = "sha256-sjqhvlt0YprWJP0BNlwOTfbYh4RzmD8zc0lDPvNJwfc=";
        };
  })
]
