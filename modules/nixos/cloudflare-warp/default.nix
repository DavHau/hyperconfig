# Cloudflare WARP client + noctalia bar icon toggling the tunnel.
#
# warp-svc runs as a system service (nixpkgs services.cloudflare-warp);
# warp-cli talks to it over its socket, so connect/disconnect needs no
# privileges. ToS is accepted automatically (--accept-tos on every call)
# and the first click registers the client if needed, so there is no
# manual setup step.
#
# Bar: a hyperconfig/status-button widget (../noctalia/plugins) polls
# `warp-toggle status` (JSON: icon/tooltip/iconColor) and runs
# `warp-toggle toggle` on click.
#
# Coexisting with the overlay VPNs (zerotier, yggdrasil, wireguard,
# tailscale):
# - Overlay address ranges WARP doesn't exclude by default (its defaults
#   already cover RFC1918, 100.64/10, fc00::/7, ...) are added to the
#   split-tunnel exclude list by cloudflare-warp-excludes, so overlay
#   traffic stays on its own interface.
# - nft-wrap.sh lets system services through WARP's firewall so daemons
#   that pin their underlay to the uplink (zerotier) keep working.
#
# Why WARP never connected on amy (2026-11-22, v4-only hotel Wi-Fi):
# - Mode `warp` (WARP's own DNS proxy on 127.0.2.2) can't work with
#   ../encrypted-dns.nix: WARP checks its proxy by resolving
#   `connectivity-check.warp-svc.` through getaddrinfo, which nss-resolve
#   answers (NXDOMAIN) without ever reading the resolv.conf WARP rewrote:
#   "Connectivity check failed due to DNS Lookup Failed", forever
#   "Connecting". The toggle therefore connects in `tunnel_only` mode:
#   the tunnel without the DNS takeover; DNS stays dnscrypt-proxy (DoH),
#   whose connections then ride the tunnel. Tested live: "Connected,
#   healthy", v4 and v6 via WARP (MASQUE over HTTP/2 on TCP 443 when UDP
#   is blocked), the mesh up.
# - systemd-networkd deleted WARP's routing rule (5209, `not fwmark
#   0x100cf lookup 65743`) as "foreign" whenever it reconfigured a link
#   it manages (WarpFwmarkRulesChanged Complete -> Absent in the log):
#   traffic then missed the tunnel and hit WARP's leak firewall. Rules
#   now belong to whoever adds them (ManageForeignRoutingPolicyRules).
# - warp-mesh-guard: while WARP is connected, a 15 s tick pings som and
#   edi over yggdrasil; 4 silent ticks in a row (both unreachable)
#   disconnect WARP, so the bar button can never strand the laptop off
#   the mesh. Only where the mesh answered before WARP connected (the
#   v6 fallback's health state, ../v6-fallback): on a network that blocks
#   the mesh anyway WARP stays on.
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
            # tunnel only: WARP's DNS mode can't work beside encrypted-dns
            # (see the header).
            ${warp-cli} --accept-tos mode tunnel_only >/dev/null
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

  nftWrap = pkgs.writeShellApplication {
    name = "warp-nft";
    runtimeInputs = [
      pkgs.gnused
      pkgs.nftables
    ];
    text = builtins.readFile ./nft-wrap.sh;
  };

  meshProbes = lib.filter (a: a != null) (
    map (
      m:
      let
        dir = config.clan.core.settings.directory or null;
        f = dir + "/vars/per-machine/${m}/yggdrasil/address/value";
      in
      if dir != null && builtins.pathExists f then lib.trim (builtins.readFile f) else null
    ) [ "som" "edi" ]
  );

  meshGuard = pkgs.writeShellApplication {
    name = "warp-mesh-guard";
    runtimeInputs = [
      pkgs.gnugrep
      pkgs.iputils
      pkgs.coreutils
    ];
    text = ''
      f=/run/warp-mesh-guard.fails
      base=/run/warp-mesh-guard.mesh-was-up
      probes=(${lib.escapeShellArgs meshProbes})
      st=$(${warp-cli} --accept-tos status 2>/dev/null || true)
      if ! grep -q 'Status update: Connected' <<<"$st"; then
        rm -f "$f"
        # Baseline without probes of our own: the IPv6 fallback's tick
        # (../v6-fallback) pings som over yggdrasil every 10 s anyway.
        if [[ -e /run/v6-fallback/up ]]; then touch "$base"; else rm -f "$base"; fi
        exit 0
      fi
      # Act only where the mesh worked before WARP came up: on a network
      # that blocks the mesh anyway, WARP stays on.
      [[ -e $base && ''${#probes[@]} -gt 0 ]] || exit 0
      for a in "''${probes[@]}"; do
        if ping -6 -n -q -c1 -W5 "$a" >/dev/null 2>&1; then
          rm -f "$f"
          exit 0
        fi
      done
      n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
      echo "$n" >"$f"
      echo "warp-mesh-guard: mesh silent with WARP on ($n)"
      if ((n >= 4)); then
        echo "warp-mesh-guard: disconnecting WARP to keep the mesh"
        ${warp-cli} --accept-tos disconnect || true
        rm -f "$f"
      fi
    '';
  };

  # Overlay ranges outside WARP's default exclude list.
  excludedRanges = lib.optional config.services.yggdrasil.enable "200::/7";
in
{
  services.cloudflare-warp.enable = true;

  environment.systemPackages = [ toggle ];

  # The guard's "mesh was up" baseline is the fallback's health state.
  assertions = [
    {
      assertion = config.hyper.v6Fallback.enable or false;
      message = "cloudflare-warp's warp-mesh-guard reads ../v6-fallback's health state: import and enable it";
    }
  ];

  # See the header: WARP's rule 5209 is not networkd's to delete.
  systemd.network.config.networkConfig.ManageForeignRoutingPolicyRules = false;

  systemd.services.warp-mesh-guard = {
    description = "Disconnect WARP when it cuts the mesh";
    after = [ "cloudflare-warp.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe meshGuard;
    };
  };
  systemd.timers.warp-mesh-guard = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "30s";
      OnUnitActiveSec = "15s";
      AccuracySec = "1s";
    };
  };

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
      ranges=(${lib.escapeShellArgs excludedRanges})
      for r in "''${ranges[@]}"; do
        if ! awk '{print $1}' <<<"$list" | grep -qxF -- "$r"; then
          warp-cli --accept-tos tunnel ip add-range "$r"
        fi
      done
    '';
  };

  services.noctalia.settings = {
    bar.default.end = [ "warp" ];
    widget.warp = {
      type = "hyperconfig/status-button:button";
      glyph = "shield";
      status_command = "${lib.getExe toggle} status";
      toggle_command = "${lib.getExe toggle} toggle";
    };
  };
}
