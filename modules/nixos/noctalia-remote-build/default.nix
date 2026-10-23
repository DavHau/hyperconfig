# Noctalia bar icon toggling remote-builders.service (remote nix builds).
#
# A hyperconfig/status-button widget (../noctalia/plugins) polls
# `remote-build-toggle status` (JSON: icon/tooltip/iconColor) and runs
# `remote-build-toggle toggle` on click, refreshing right after. Toggling
# needs no password: the remote-building client role ships a polkit rule
# for wheel on exactly this unit.
{ lib, pkgs, ... }:
let
  toggle = pkgs.writeShellApplication {
    name = "remote-build-toggle";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      unit=remote-builders.service
      case "''${1:-}" in
        status)
          if systemctl is-active --quiet "$unit"; then
            printf '{"icon":"cloud-upload","iconColor":"primary","tooltip":"Remote builds: ON — click to build locally"}\n'
          else
            printf '{"icon":"cloud-off","tooltip":"Remote builds: OFF — click to offload"}\n'
          fi
          ;;
        toggle)
          if systemctl is-active --quiet "$unit"; then
            systemctl stop "$unit"
          else
            systemctl start "$unit"
          fi
          ;;
        *)
          echo "usage: remote-build-toggle {status|toggle}" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  environment.systemPackages = [ toggle ];

  services.noctalia.settings = {
    bar.default.end = [ "remote-build" ];
    widget.remote-build = {
      type = "hyperconfig/status-button:button";
      glyph = "cloud-upload";
      status_command = "${lib.getExe toggle} status";
      toggle_command = "${lib.getExe toggle} toggle";
    };
  };
}
