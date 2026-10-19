# Owner gate on the hermes oauth2-proxy instances: the front door's
# (./hermes-dashboard-public.nix) and the private serve ports'
# (./hermes-agents-serve.nix, hyper.hermesOauth2Gate.ports): only nginx and
# root may open connections to their loopback ports.
#
# Nothing else needs those ports, and every local uid (every agent) could
# otherwise talk to them directly, past nginx: the sign-in endpoints with
# X-Forwarded-* headers of its choosing (the serve ports' instance builds
# its callback URL from X-Forwarded-Host). The proxies trust those headers
# from 127.0.0.1 only (trusted-proxy-ip), which after this gate means
# nginx. The mail owner page's instance has the same gate
# (./agent-mail/owner-page.nix).
#
# A unit and chain of its own, like mailgate-firewall: the gate belongs to
# these proxies, not to the agents' firewall (hermes-firewall), and holds
# wherever they run.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  oauth2 = config.services.oauth2-proxy;
  # "http://127.0.0.1:4180" -> "4180"
  frontPort = lib.toInt (lib.last (lib.splitString ":" oauth2.httpAddress));
  ports = [ frontPort ] ++ config.hyper.hermesOauth2Gate.ports;
  chain = "hermes-oauth2-gate";
in
{
  options.hyper.hermesOauth2Gate.ports = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ ];
    description = "Loopback ports of further oauth2-proxy instances that only nginx and root may dial (the front door's is always gated). Their units should require hermes-oauth2-gate.service.";
  };

  config = lib.mkIf (oauth2.enable && config.services.nginx.enable) {
    systemd.services.hermes-oauth2-gate = {
      description = "Owner gate on the hermes oauth2-proxy ports";
      wantedBy = [ "multi-user.target" ];
      # The owner-match rule needs the nginx user at insert time; both
      # firewall backends flush at start, so this comes after them and
      # re-inserts whenever they restart.
      after = [
        "userborn.service"
        "firewall.service"
        "nftables.service"
      ];
      before = [ "oauth2-proxy.service" ];
      partOf =
        lib.optional config.networking.nftables.enable "nftables.service"
        ++ lib.optional (!config.networking.nftables.enable) "firewall.service";
      path = [ pkgs.iptables ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for ipt in iptables ip6tables; do
          $ipt -w -N ${chain} 2>/dev/null || true
          $ipt -w -F ${chain}
          for port in ${lib.concatMapStringsSep " " toString ports}; do
            for u in ${config.services.nginx.user} 0; do
              $ipt -w -A ${chain} -p tcp --dport "$port" -m owner --uid-owner "$u" -j RETURN
            done
            $ipt -w -A ${chain} -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
          done
          $ipt -w -C OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain} 2>/dev/null \
            || $ipt -w -I OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain}
        done
      '';
      preStop = ''
        for ipt in iptables ip6tables; do
          $ipt -w -D OUTPUT -o lo -p tcp -m conntrack --ctstate NEW -j ${chain} 2>/dev/null || true
          $ipt -w -F ${chain} 2>/dev/null || true
          $ipt -w -X ${chain} 2>/dev/null || true
        done
      '';
    };

    # The proxy does not run ungated.
    systemd.services.oauth2-proxy = {
      requires = [ "hermes-oauth2-gate.service" ];
      after = [ "hermes-oauth2-gate.service" ];
    };
  };
}
