# ntop: nix-native htop from the local ../ntop checkout (input in flake.nix).
# One TUI for live builds, substituter transfers, store usage and remote
# builders. Real mode needs root -- it reads nixbld* /proc environs and loads
# eBPF write(2) probes -- so it is invoked as `sudo ntop`; `ntop --mock` runs
# unprivileged. Nothing to configure, the binary is self-contained.
{ pkgs, inputs, ... }:
{
  environment.systemPackages = [
    inputs.ntop.packages.${pkgs.stdenv.hostPlatform.system}.ntop
  ];
}
