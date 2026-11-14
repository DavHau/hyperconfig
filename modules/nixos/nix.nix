# The nix package on Dave's desktops: input `nix` (DavHau/nix
# parallel-downloads, see ./nix-parallel-downloads.nix).
{inputs, ...}: {
  nix.package = inputs.nix.packages.x86_64-linux.default;
}
