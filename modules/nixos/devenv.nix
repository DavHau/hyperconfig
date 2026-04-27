{config, inputs, pkgs, ...}: {
  environment.systemPackages = [
    inputs.devenv.packages.${pkgs.stdenv.hostPlatform.system}.devenv
  ];
}
