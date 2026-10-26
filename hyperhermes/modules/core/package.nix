# The hermes package the agents run: upstream's, with the wheel patches
# in ./patches. The default of services.hyperhermes.package.
#
# hermes patches cannot ride an overrideAttrs: upstream seals the venv
# from a source filter rooted in its own nix/ directory, and the built
# package only symlinks into that venv. So the package is built again
# through upstream's own nix/packages.nix, with upstream's own inputs. The
# hermes-agent nixpkgs input follows this flake's, so the deps are the
# same store paths; only the hermes-agent wheel and the venv rebuild.
#
# Not from a patched copy of the source (pkgs.applyPatches): importing
# nix/packages.nix from it would be import-from-derivation. Instead the
# uv2nix input that packages.nix receives gets one more overlay that
# patches the hermes-agent wheel. The wheel source drops tests/, so
# filterdiff drops the test hunks.
{
  lib,
  system,
  hermes-agent,
}:
let
  hermesInputs = hermes-agent.inputs;
  hermesPkgs = hermesInputs.nixpkgs.legacyPackages.${system};
  hermesWheelPatches = [
    ./patches/hermes-auth-bare-named-provider.patch
    ./patches/hermes-gateway-restart-foreign-unit.patch
    ./patches/hermes-gateway-no-home-shutdown-broadcast.patch
    ./patches/hermes-camofox-browser-downloads.patch
    ./patches/hermes-camofox-solve-captcha.patch
    ./patches/hermes-camofox-vault.patch
    ./patches/hermes-hosted-ocr-url.patch
  ];
  patchHermesWheel = _final: prev: {
    hermes-agent = prev.hermes-agent.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ hermesPkgs.patchutils ];
      postPatch =
        (old.postPatch or "")
        + lib.concatMapStrings (p: ''
          filterdiff -p1 -x 'tests/*' ${p} | patch -p1
        '') hermesWheelPatches;
    });
  };
  uv2nixPatched = lib.recursiveUpdate hermesInputs.uv2nix {
    lib.workspace.loadWorkspace =
      args:
      let
        workspace = hermesInputs.uv2nix.lib.workspace.loadWorkspace args;
      in
      workspace
      // {
        mkPyprojectOverlay =
          overlayArgs: lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) patchHermesWheel;
      };
  };

  hermesUpstream =
    (import "${hermes-agent}/nix/packages.nix" {
      # rev = null: no HERMES_REVISION, so the wrapper does not change with
      # the consumer's revision. Upstream reads `inputs.self.rev or null`.
      inputs = hermesInputs // {
        self = { };
        uv2nix = uv2nixPatched;
      };
    }).perSystem
      {
        pkgs = hermesPkgs;
        inherit lib;
        inputs'.npm-lockfile-fix.packages.default =
          hermesInputs.npm-lockfile-fix.packages.${system}.default;
      };
in
hermesUpstream.packages.default
