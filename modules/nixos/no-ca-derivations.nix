/*
  Keeps nix's experimental `ca-derivations` feature off on every machine
  (imported by ./common.nix), see docs/security/nix-ca-realisation.md:
  with it on, an unprivileged nix-daemon client can register realisations
  without a signature check (GHSA-jm6c-h95p-6qhj, unfixed in nix 2.35.x).
  The fleet builds no CA derivations. Side effect: `impure-derivations`
  stays listed but is unusable (nix requires ca-derivations for
  `__impure`); nothing in the repo uses it.

  spaces' modules/nixos/nix.nix adds the feature for nix >= 2.28 (amy, som,
  vit via dave.nix). The mkForce below recomputes experimental-features
  from every other definition with ca-derivations filtered out, so all
  other features stay as their modules set them. The assertion fails
  evaluation if it comes back anyway (a second mkForce, extraOptions).
*/
{
  config,
  lib,
  options,
  ...
}: let
  feature = "ca-derivations";
  self = toString ./no-ca-derivations.nix;
  # nix.settings as merged from every module but this one: no recursion
  # through our own mkForce, and mkIf/mkDefault/mkMerge resolve as usual.
  others = builtins.filter (d: d.file != self) options.nix.settings.definitionsWithLocations;
  unforced =
    (lib.modules.mergeDefinitions ["nix" "settings"] options.nix.settings.type others)
    .mergedValue.experimental-features;
in {
  nix.settings.experimental-features = lib.mkForce (lib.remove feature unforced);

  assertions = [
    {
      assertion =
        !(builtins.elem feature config.nix.settings.experimental-features)
        && !(builtins.elem feature (lib.toList (config.nix.settings.extra-experimental-features or [ ])))
        && !(lib.hasInfix feature config.nix.extraOptions);
      message = ''
        nix experimental feature `${feature}` is enabled, but must stay off
        fleet-wide: untrusted nix-daemon clients could register unsigned
        realisations (GHSA-jm6c-h95p-6qhj). See
        docs/security/nix-ca-realisation.md and modules/nixos/no-ca-derivations.nix.
      '';
    }
  ];
}
