/*
  nix-housing (codeberg.org/decentstates/nix-housing): Landlock-sandboxed
  per-user shell environments, run with `house-<name>`. Houses are declared by
  the importing user module via `housing.users.<user>.houses.<name>`.

  The runner restricts with Landlock ABI 9 and has no best-effort fallback, so
  on kernels older than 7.1 `house-*` exits with a landlock error. That
  failure stays contained to explicit invocations: the NixOS module, unlike
  the home-manager one, runs nothing inside a house during activation.
*/
{ inputs, ... }:
{
  imports = [ inputs.nix-housing.nixosModules.default ];

  housing.enable = true;
}
