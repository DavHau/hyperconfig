# Noctalia bar icon toggling remote-builders.service (remote nix builds).
#
# No QML: noctalia's built-in CustomButton widget polls
# `remote-build-toggle status` (JSON: icon/tooltip/iconColor) and runs
# `remote-build-toggle toggle` on click; leftClickUpdateText refreshes the
# icon immediately after the click. Toggling needs no password: the
# remote-building client role ships a polkit rule for wheel on exactly
# this unit.
#
# merge.sh seeds the widget into ~/.config/noctalia/settings.json as an
# extra noctalia-shell ExecStartPre AFTER the spaces bundle's
# noctalia-config-merge — append-only and idempotent, the user's own
# layout survives (same contract as noctalia-anthropic-usage).
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
            printf '{"icon":"cloud_upload","iconColor":"primary","tooltip":"Remote builds: ON — click to build locally"}\n'
          else
            printf '{"icon":"cloud_off","tooltip":"Remote builds: OFF — click to offload"}\n'
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

  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-remote-build-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./merge.sh;
  };
in
{
  environment.systemPackages = [ toggle ];

  systemd.user.services.noctalia-shell = {
    # After the spaces bundle's noctalia-config-merge (mkAfter), so the
    # managed settings.json is already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-remote-build-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
