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

  # firefox-unwrapped 161.0 (som, vit; sandbox escapes):
  # CVE-2026-135501, CVE-2026-135506, CVE-2026-135508, CVE-2026-135509,
  # CVE-2026-135510, CVE-2026-135513, CVE-2026-135519, CVE-2026-135520,
  # CVE-2026-135521, CVE-2026-135525, CVE-2026-135529, CVE-2026-135530,
  # CVE-2026-135547, CVE-2026-135571, CVE-2026-135578, CVE-2026-135582,
  # CVE-2026-135596, CVE-2026-135597. Same version/hash as upstream
  # nixpkgs; buildMozillaMach's version-gated patches and inputs are the
  # same for 160 and 161. passthru.version must follow (it shadows the
  # derivation's version). Drop once nixpkgs firefox-unwrapped >= 161.0.
  (final: prev: {
    firefox-unwrapped =
      if prev.lib.versionAtLeast prev.firefox-unwrapped.version "161.0" then
        prev.firefox-unwrapped
      else
        prev.firefox-unwrapped.overrideAttrs (o: {
          version = "161.0";
          src = prev.fetchurl {
            url = "mirror://mozilla/firefox/releases/161.0/source/firefox-161.0.source.tar.xz";
            sha512 = "d456b1cb9d514f5be90ec9b4104dc5545dfc3a4a8626e2d862fdc60b6e8c769abfb37045ffc7abd1f8afcdef4eecba67f7ab367d8496fbae374626abd756631d";
          };
          passthru = o.passthru // {
            version = "161.0";
          };
        });
  })
]
