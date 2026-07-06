{ config, pkgs, lib, inputs, ... }:
# wdisplays + niri-display persistence.
#
# wdisplays is wrapped via lassulus/wrappers so that whenever the GUI is
# closed, scripts/save-niri-displays.py runs to snapshot the current niri
# output configuration to ~/.config/niri/displays.kdl. The include below
# merges into the /etc/niri/config-laptop.kdl wrapper (created by
# ./niri-monitor-binds.nix, which points NIRI_CONFIG at it), so the layout
# the user arranged interactively survives across sessions.
let
  saveNiriDisplays = pkgs.writers.writePython3Bin "save-niri-displays" {
    flakeIgnore = [ "E265" "E501" "W503" ];
  } (builtins.readFile ../../scripts/save-niri-displays.py);

  # The script shells out to `niri msg --json outputs`; ensure niri is on PATH.
  saveNiriDisplaysWrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = saveNiriDisplays;
    runtimeInputs = [ pkgs.niri ];
  };

  wdisplaysWrapped = inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = pkgs.wdisplays;
    # Snapshot only on a clean exit. The wrapper enables `set -e`, so a
    # non-zero wdisplays exit aborts before postHook runs -- which is what
    # we want: never persist a layout from a crashed/killed session.
    postHook = ''
      ${lib.getExe saveNiriDisplaysWrapped} || \
        echo "save-niri-displays: snapshot failed" >&2
    '';
  };
in
{
  environment.systemPackages = [
    wdisplaysWrapped
    saveNiriDisplaysWrapped
  ];

  # Load the persisted output layout; optional so a fresh machine (no
  # snapshot yet) still gets a valid config.
  environment.etc."niri/config-laptop.kdl".text = ''
    include optional=true "~/.config/niri/displays.kdl"
  '';
}
