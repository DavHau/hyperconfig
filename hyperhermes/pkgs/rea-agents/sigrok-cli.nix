# sigrok-cli for REA's signal-recording tools: REA accepts exactly the
# 0.7.2 release (`--version` must start `sigrok-cli 0.7.2`; its decoder
# and error parsers follow that release's output). nixpkgs builds a
# 0.8.0 git snapshot, so this is its recipe on the 0.7.2 tarball, against
# nixpkgs' libsigrok and libsigrokdecode.
{ fetchurl, sigrok-cli }:
sigrok-cli.overrideAttrs (
  finalAttrs: _: {
    version = "0.7.2";
    src = fetchurl {
      url = "https://sigrok.org/download/source/sigrok-cli/sigrok-cli-${finalAttrs.version}.tar.gz";
      hash = "sha256-cdBEPzaJe/Vlcy3sIGgw2+oPJ4m2YBzxBTayhtEUCrg=";
    };
  }
)
