{config, inputs, pkgs, ...}: {
  environment.systemPackages = [
    inputs.devenv.packages.${pkgs.system}.devenv
  ];
}
