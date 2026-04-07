{pkgs, ...}: {
  imports = [
    ./pinentry.nix
  ];
  environment.systemPackages = [
    # provides the executable `bw`
    pkgs.bitwarden-cli
  ];
}
