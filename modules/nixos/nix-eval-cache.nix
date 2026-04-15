{
  pkgs,
  inputs,
  ...
}: let
  nix-eval-cache = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = inputs.nix-eval-cache.packages.x86_64-linux.nix-cli;
    binName = "nix-eval-cache";
    env = {
      _NIX_TRACING_CACHE_LOGGING = "1";
    };
    args = [
      "--extra-experimental-features" "tracing-eval-cache"
      "--option" "tracing-eval-cache" "true"
    ];
  };
in {
  environment.systemPackages = [
    nix-eval-cache
  ];
}
