# Dave's dictation take archive: voxtype, patched to keep every take
# (./take-archive.patch), and the `voxtype-archive` tool that files each
# take as FLAC + JSON sidecar and replays it (./voxtype-archive.sh).
# Module: modules/nixos/voxtype-archive.nix.
{
  writeShellApplication,
  flac,
  jq,
  coreutils,
  findutils,
  util-linux,
  # voxtype's flake package set for this system and the variant to patch
  # (spaces.voxtype.variant).
  voxtypePackages,
  variant,
}:
let
  # Each variant is a symlinkJoin wrapper (wrapVoxtype / wrapOnnx: PATH,
  # ORT_DYLIB_PATH) around one unwrapped build, which the flake also
  # exports as voxtype[-<variant>]-unwrapped. Patch that build and swap it
  # into the wrapper; `paths` of the wrapper itself are plain strings.
  unwrapped =
    voxtypePackages.${if variant == "default" then "voxtype-unwrapped" else "voxtype-${variant}-unwrapped"};
  patchedUnwrapped = unwrapped.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./take-archive.patch ];
    # voxtype's whole suite (incl. take_archive's tests) passes in the
    # sandbox; explicit so an upstream doCheck = false can't drop it.
    doCheck = true;
  });
  patched = voxtypePackages.${variant}.overrideAttrs (old: {
    paths = [ patchedUnwrapped ];
    passthru = (old.passthru or { }) // {
      unwrapped = patchedUnwrapped;
    };
  });
in
{
  voxtype = patched;
  tool = writeShellApplication {
    name = "voxtype-archive";
    runtimeInputs = [
      flac
      jq
      coreutils
      findutils
      util-linux
      patched
    ];
    text = builtins.readFile ./voxtype-archive.sh;
  };
}
