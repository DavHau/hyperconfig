# lego's DNS-01 orders on a machine behind the home router (cm-beryl).
#
# The router intercepts every plaintext DNS packet from the LAN (GL.iNet
# "force DNS", gl-dns-v2.force_dns=1) and answers it from its own resolver,
# whatever address it was sent to. So lego can neither use a public
# resolver (1.1.1.1:53 lands on the router: timeouts, REFUSED for names that
# do not exist yet) nor ask the zone's authoritative servers directly
# (porkbun's nameservers "answer" REFUSED: it is the router).
#
# Instead every certificate here uses the machine's own encrypted resolver
# (systemd-resolved on 127.0.0.53 -> dnscrypt-proxy, ./encrypted-dns.nix),
# which the router cannot see into, for the zone lookup and the recursive
# propagation check, and skips only the check against the authoritative
# servers.
{ config, lib, ... }:
{
  security.acme.defaults.dnsResolver = "127.0.0.53:53";

  systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "acme-order-renew-${name}" {
      environment.LEGO_DNS_PROPAGATION_DISABLE_ANS = "true";
    }
  ) config.security.acme.certs;
}
