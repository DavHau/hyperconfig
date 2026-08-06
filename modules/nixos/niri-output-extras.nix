# Declarative per-output niri config extras (e.g. per-monitor layout).
#
# niri applies exactly ONE `output` section per monitor -- the first whose
# name matches (niri-config/src/output.rs Outputs::find) -- with no merging
# across sections. The monitor geometry sections are owned by the
# ~/.config/niri/displays.kdl snapshot (see ./wdisplays.nix), so extras like
# per-output `layout {}` cannot live in their own nix-owned section: before
# the snapshot include they would shadow the snapshotted geometry, after it
# they would be dead config.
#
# Instead this module writes the extras to /etc/niri/output-extras.json,
# which scripts/save-niri-displays.py merges into each matching snapshot
# block at snapshot time. The `output` sections emitted below (ordered after
# the displays.kdl include via mkAfter) only cover monitors absent from the
# snapshot -- a fresh machine, a stale snapshot, or a never-snapshotted
# monitor -- where they are the first match and niri falls back to automatic
# geometry.
#
# After changing extras, re-run `save-niri-displays` (or close wdisplays
# once) to fold them into an existing snapshot.
{ config, lib, ... }:
let
  cfg = config.niri.outputExtras;

  renderSection = name: body: ''
    output "${name}" {
    ${body}}
  '';
in
{
  options.niri.outputExtras = lib.mkOption {
    type = lib.types.attrsOf lib.types.lines;
    default = { };
    description = ''
      Extra kdl config per niri output, keyed by output name: a connector
      ("DP-2") or "Make Model Serial" (as shown by `niri msg outputs`,
      "Unknown" for missing parts), case-insensitive.
    '';
    example = {
      "Samsung Electric Company LS32D80xU HNBY600016" = ''
        layout {
            default-column-width { proportion 0.33333; }
        }
      '';
    };
  };

  config = lib.mkIf (cfg != { }) {
    environment.etc."niri/output-extras.json".text = builtins.toJSON cfg;

    environment.etc."niri/config-laptop.kdl".text = lib.mkAfter (
      lib.concatStrings (lib.mapAttrsToList renderSection cfg)
    );
  };
}
