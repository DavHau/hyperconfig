# Owner gate on the dashboards' oauth2-proxy (./hermes-dashboard-public.nix):
# only nginx and root may open connections to its loopback port.
#
# Nothing else needs that port, and every local uid (every agent) could
# otherwise talk to it directly, past nginx: the sign-in endpoints with
# X-Forwarded-* headers of its choosing. The proxy trusts those headers from
# 127.0.0.1 only (trustedProxyIP), which after this gate means nginx. The
# mail owner page's instance has the same gate (./agent-mail/owner-page.nix).
#
# A unit and chain of its own, like mailgate-firewall: the gate belongs to
# this proxy, not to the agents' firewall (hermes-firewall), and holds
# wherever the proxy runs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  oauth2 = config.services.oauth2-proxy;
  # "http://127.0.0.1:4180" -> "4180"
  port = lib.last (lib.splitString ":" oauth2.httpAddress);
  chain = "hermes-oauth2-gate";
in
{
  config = lib.mkIf (oauth2.enable && config.services.nginx.enable) {
    systemd.services.hermes-oauth2-gate = {
      description = "Owner gate on the dashboards' oauth2-proxy port";
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
          for u in ${config.services.nginx.user} 0; do
            $ipt -w -A ${chain} -p tcp --dport ${port} -m owner --uid-owner "$u" -j RETURN
          done
          $ipt -w -A ${chain} -p tcp --dport ${port} -j REJECT --reject-with tcp-reset
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
