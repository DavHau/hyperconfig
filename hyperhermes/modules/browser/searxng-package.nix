# The SearXNG package of ./searxng.nix: nixpkgs' searxng, optionally built
# from another source (browser.searxng.source, e.g. a flake input pinned
# to upstream master), plus our patches. Also called by consumers that need
# the exact same build outside the module (hyperconfig's search canary
# runs a scratch instance of a candidate version with it).
#
# `source`: null (nixpkgs' own src) or a source tree that carries `rev`
# and `lastModifiedDate` (a flake input with flake = false does). Our
# patches apply to both: the build fails loudly once upstream moves the
# code they touch.
{
  pkgs,
  source ? null,
}:
let
  inherit (pkgs) lib;
  date =
    d: "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
in
pkgs.searxng.overrideAttrs (
  old:
  lib.optionalAttrs (source != null) {
    version = "0-unstable-${date source.lastModifiedDate}";
    src = source;
    # nixpkgs relaxes its snapshot's pins (its postPatch, kept: ours is
    # appended); master's requirements.txt moves faster than nixpkgs'
    # python set (2026-11: python-dateutil 3.0.0, typer 0.29, msgspec
    # 0.22 against 2.9/0.27/0.21) and postInstall's `pip install
    # --dry-run` would fail on a bound nixpkgs lacks. So every bound left
    # after nixpkgs' edits is dropped too, names kept: the dependency set
    # still comes from nixpkgs' package and the dry run still fails on a
    # NEW requirement nixpkgs does not provide. What was dropped is in the
    # build log and in $out/share/searxng/stripped-requirements.txt (the
    # nightly bump's review reads it).
    postPatch = (old.postPatch or "") + ''
      grep -E '[=<>~!]' requirements.txt >stripped-requirements.txt || true
      echo "searxng-package: dropping these requirement bounds:" >&2
      cat stripped-requirements.txt >&2
      sed -i -E 's/[[:space:]]*([=<>~!]=|[<>]).*$//' requirements.txt
    '';
    postInstall = (old.postInstall or "") + ''
      install -Dm0644 stripped-requirements.txt $out/share/searxng/stripped-requirements.txt
    '';
  }
  // {
    patches = (old.patches or [ ]) ++ [
      # Firefox UAs (gen_useragent) get Firefox's TLS/HTTP2 fingerprint
      # instead of the default Chrome one. Not a global switch: Yahoo
      # answers 500 to curl_cffi's firefox147 target.
      ./patches/searxng-firefox-ua-fingerprint.patch
    ];
  }
)
