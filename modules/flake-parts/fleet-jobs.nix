/*
  fleetJobs: the jobs the nixpkgs bump must build, one flake attribute
  (docs: the recurring-tasks redesign, DESIGN 3.1 A.2). The deterministic
  bump (../nixos/infra-space/fleet-bump) builds every job of one cadence,
  one after another, and reports each as ok or fail:

    nix eval --json .#fleetJobs.nightly --apply builtins.attrNames
    nix build .#fleetJobs.nightly.<job>

  Jobs, derived from the clan's machines (a new machine is gated by
  default, nobody has to remember to list it):
    <machine>        its toplevel, built (every machine but the ones below)
    installer-kexec  the installer's two images, built; never its toplevel
    installer-iso    (tmpfs root, no boot loader, never deployed)
    eval-cm-pi       cm-pi's toplevel evaluated only (drvPath, context
                     discarded) on the nightly; built on the weekly as
                     `cm-pi` (a cross toolchain from source, ~6 h)
    checks-eval      every flake check evaluated (their drvPaths, context
                     discarded): what `nix flake check --no-build` gates,
                     clanTest's IFD included; no check is built

  Cadence per machine in `cadence` below: vit is nightly for now; it moves
  to the weekly once its CUDA set has its own input (DESIGN 3.4), by
  changing its entry, nothing else. `hold` (DESIGN 3.5, per-machine hold,
  none yet) drops a machine from every cadence.
*/
{ self, inputs, lib, ... }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  machines = self.nixosConfigurations;

  # Machines on per-machine hold: not built by the bump (none yet).
  hold = [ ];

  # "nightly" or "weekly"; machines not named here are nightly.
  cadence = {
    cm-pi = "weekly";
    # nightly until the nixpkgs-cuda input moves its CUDA set out (DESIGN 3.4)
    vit = "nightly";
  };
  cadenceOf = m: cadence.${m} or "nightly";

  toplevel = m: machines.${m}.config.system.build.toplevel;
  evalOnly =
    name: drvPath:
    pkgs.writeText name (builtins.unsafeDiscardStringContext drvPath);

  machineJobs =
    m:
    if m == "installer" then
      {
        installer-kexec = machines.installer.config.system.build.images.kexecTarball;
        installer-iso = machines.installer.config.system.build.images.iso;
      }
    else
      { ${m} = toplevel m; };

  active = lib.filter (m: !lib.elem m hold) (lib.attrNames machines);
  ofCadence = c: lib.filter (m: cadenceOf m == c) active;
  jobsOf = c: lib.foldl' (acc: m: acc // machineJobs m) { } (ofCadence c);
in
{
  flake.fleetJobs =
    assert lib.all (m: machines ? ${m}) (hold ++ lib.attrNames cadence);
    {
      nightly =
        jobsOf "nightly"
        # the weekly machines evaluated every night
        // lib.listToAttrs (
          map (m: lib.nameValuePair "eval-${m}" (evalOnly "eval-${m}" (toplevel m).drvPath)) (
            ofCadence "weekly"
          )
        )
        // {
          checks-eval = pkgs.writeText "checks-eval" (
            builtins.unsafeDiscardStringContext (
              builtins.toJSON (builtins.mapAttrs (_: c: c.drvPath) self.checks.x86_64-linux)
            )
          );
        };
      weekly = jobsOf "weekly";
    };
}
