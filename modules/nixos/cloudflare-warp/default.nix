# Cloudflare WARP client + noctalia bar icon toggling the tunnel.
#
# warp-svc runs as a system service (nixpkgs services.cloudflare-warp);
# warp-cli talks to it over its socket, so connect/disconnect needs no
# privileges. ToS is accepted automatically (--accept-tos on every call)
# and the first click registers the client if needed, so there is no
# manual setup step.
#
# Bar: noctalia's built-in CustomButton polls `warp-toggle status`
# (JSON: icon/tooltip/iconColor) and runs `warp-toggle toggle` on click.
#
# merge.sh seeds the widget into ~/.config/noctalia/settings.json as an
# extra noctalia-shell ExecStartPre (same contract as noctalia-remote-build).
{ lib, pkgs, config, ... }:
let
  warp-cli = "${config.services.cloudflare-warp.package}/bin/warp-cli";

  toggle = pkgs.writeShellApplication {
    name = "warp-toggle";
    runtimeInputs = [ pkgs.gnugrep ];
    text = ''
      state() { ${warp-cli} --accept-tos status 2>&1 || true; }
      case "''${1:-}" in
        status)
          s="$(state)"
          if grep -q 'Status update: Connected' <<<"$s"; then
            printf '{"icon":"shield-check","iconColor":"primary","tooltip":"WARP: ON — click to disconnect"}\n'
          elif grep -qi 'registration' <<<"$s"; then
            printf '{"icon":"shield-x","tooltip":"WARP: not registered — click to register and connect"}\n'
          elif grep -q 'Status update: Connecting' <<<"$s"; then
            printf '{"icon":"shield","tooltip":"WARP: connecting…"}\n'
          else
            printf '{"icon":"shield-off","tooltip":"WARP: OFF — click to connect"}\n'
          fi
          ;;
        toggle)
          s="$(state)"
          if grep -qE 'Status update: (Connected|Connecting)' <<<"$s"; then
            ${warp-cli} --accept-tos disconnect
          else
            if grep -qi 'registration' <<<"$s"; then
              ${warp-cli} --accept-tos registration new
            fi
            ${warp-cli} --accept-tos connect
          fi
          ;;
        *)
          echo "usage: warp-toggle {status|toggle}" >&2
          exit 2
          ;;
      esac
    '';
  };

  mergeConfig = pkgs.writeShellApplication {
    name = "noctalia-warp-merge";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
    text = builtins.readFile ./merge.sh;
  };
in
{
  services.cloudflare-warp.enable = true;

  environment.systemPackages = [ toggle ];

  systemd.user.services.noctalia-shell = {
    # After the spaces bundle's noctalia-config-merge (mkAfter), so the
    # managed settings.json is already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-warp-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
