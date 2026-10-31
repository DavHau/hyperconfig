# The Python REA runs its pwntools bridges with (REA_PWNTOOLS_PYTHON:
# inspect_binary_layout, inspect_recorded_crash). REA runs it as
# `python -I`, so the libraries must be in the interpreter itself, and
# its bridge accepts exactly pwntools 4.15.0, pyelftools 0.33 and unicorn
# 2.1.2. nixpkgs has pwntools 4.15.0 but pyelftools 0.32 and unicorn
# 2.1.4; the Python unicorn takes its version and source from the C
# library, so both move to the pinned releases here.
{
  fetchFromGitHub,
  python3,
  unicorn,
}:
let
  unicorn' = unicorn.overrideAttrs (
    finalAttrs: _: {
      version = "2.1.2";
      src = fetchFromGitHub {
        owner = "unicorn-engine";
        repo = "unicorn";
        tag = finalAttrs.version;
        hash = "sha256-qA84xBztyWmt/rUExhhZMkQzvDPx0UE9MAIPG/Su3iE=";
      };
    }
  );
  python = python3.override {
    self = python;
    packageOverrides = _: prev: {
      pyelftools = prev.pyelftools.overridePythonAttrs {
        version = "0.33";
        src = fetchFromGitHub {
          owner = "eliben";
          repo = "pyelftools";
          tag = "v0.33";
          hash = "sha256-NqF5A6PRl4uncwNS9j44fIV7ovlljiucvV2Msv0LK/w=";
        };
      };
      # 2.1.2's bindings take their version from git tags (versioningit),
      # which the release source has none of.
      unicorn = (prev.unicorn.override { unicorn = unicorn'; }).overridePythonAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace pyproject.toml \
            --replace-fail 'dynamic = ["version"]' 'version = "${unicorn'.version}"' \
            --replace-fail ', "versioningit"' "" \
            --replace-fail '[tool.versioningit]' ""
        '';
      });
    };
  };
in
python.withPackages (ps: [ ps.pwntools ])
