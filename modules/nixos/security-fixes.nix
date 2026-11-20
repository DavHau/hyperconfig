# Fleet-wide package security overrides made by the unattended security
# jobs. This wrapper is fixed: sec-job-guard refuses changes to it, so a
# job cannot set NixOS options through it. The jobs edit only the overlay
# list ./security-fixes/overlays.nix and patch files next to it
# (./security-fixes/<name>.patch). Other configuration changes need a
# session.
{ ... }:
{
  nixpkgs.overlays = import ./security-fixes/overlays.nix;
}
