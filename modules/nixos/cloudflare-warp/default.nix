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
#
# Coexisting with the overlay VPNs (zerotier, yggdrasil, wireguard,
# retiolum, hyprspace, tailscale):
# - Overlay address ranges WARP doesn't exclude by default (its defaults
#   already cover RFC1918, 100.64/10, fc00::/7, ...) are added to the
#   split-tunnel exclude list by cloudflare-warp-excludes, so overlay
#   traffic stays on its own interface.
# - nft-wrap.sh lets system services through WARP's firewall so daemons
#   that pin their underlay to the uplink (zerotier) keep working.
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

  nftWrap = pkgs.writeShellApplication {
    name = "warp-nft";
    runtimeInputs = [
      pkgs.gnused
      pkgs.nftables
    ];
    text = builtins.readFile ./nft-wrap.sh;
  };

  # Overlay ranges outside WARP's default exclude list.
  excludedRanges =
    lib.optional config.services.yggdrasil.enable "200::/7"
    ++ lib.optional (config.services.tinc.networks ? retiolum) "42::/16";
in
{
  services.cloudflare-warp.enable = true;

  environment.systemPackages = [ toggle ];

  # mkForce: replaces the module's plain nftables bind with the wrapper.
  systemd.services.cloudflare-warp.serviceConfig.BindReadOnlyPaths = lib.mkForce [
    "${lib.getExe nftWrap}:/usr/sbin/nft"
  ];

  # Split-tunnel excludes live in warp-svc's mutable settings.json; add
  # any that are missing whenever the daemon (re)starts. Additive only.
  systemd.services.cloudflare-warp-excludes = {
    description = "Exclude overlay VPN ranges from the WARP tunnel";
    after = [ "cloudflare-warp.service" ];
    partOf = [ "cloudflare-warp.service" ];
    wantedBy = [ "cloudflare-warp.service" ];
    path = [ config.services.cloudflare-warp.package pkgs.gawk pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      list=""
      for _ in $(seq 30); do
        if list="$(warp-cli --accept-tos tunnel ip list 2>/dev/null)"; then break; fi
        sleep 1
      done
      for r in ${lib.escapeShellArgs excludedRanges}; do
        if ! awk '{print $1}' <<<"$list" | grep -qxF -- "$r"; then
          warp-cli --accept-tos tunnel ip add-range "$r"
        fi
      done
    '';
  };

  systemd.user.services.noctalia-shell = {
    # After the spaces bundle's noctalia-config-merge (mkAfter), so the
    # managed settings.json is already seeded.
    serviceConfig.ExecStartPre = lib.mkAfter [
      "${mergeConfig}/bin/noctalia-warp-merge"
    ];
    restartTriggers = [ mergeConfig ];
  };
}
