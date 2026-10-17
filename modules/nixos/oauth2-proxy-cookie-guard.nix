# Reject requests that carry one of oauth2-proxy's cookie names twice, or
# its session cookie both whole and split.
#
# Why: a host under the same registrable domain (on som: the agent slots,
# <agent>.slots.davhau.com, ./agent-slots.nix) can set cookies with
# Domain=davhau.com, and browsers send those to every davhau.com site next
# to the site's own. A tossed `_oauth2_proxy` (or `_csrf`) cookie with a
# longer Path is sent first, and oauth2-proxy reads the first cookie of a
# name: the visitor would silently run on the tosser's session or CSRF
# token. oauth2-proxy splits a session over ~4 KB into `_oauth2_proxy_0`,
# `_1`, … and reads those only when the whole name is absent, so a tossed
# whole `_oauth2_proxy` next to a visitor's split session wins the same
# way (and tossed pieces next to a whole one are junk at best). With both
# present the request is refused instead (400, with a hint to clear the
# site's cookies). `__Host-` cookie names would stop the
# tossing outright, but they forbid a Domain attribute, and the dashboard's
# login cookie needs Domain=<host> to cover the serve subdomains
# (./hermes-agents-serve.nix).
#
# Not covered (only a separate registrable domain for the tossing hosts
# would cover it): a tossed login cookie when the visitor has none yet, and
# junk cookies that keep a visitor out until they clear them.
{ config, lib, ... }:
let
  cfg = config.hyper.oauth2ProxyCookieGuard;
  name = config.services.oauth2-proxy.cookie.name;
in
{
  options.hyper.oauth2ProxyCookieGuard.virtualHosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "nginx virtualHosts (attribute names) that refuse a request carrying an oauth2-proxy cookie name twice, or the session cookie both whole and split.";
  };

  config = lib.mkIf (cfg.virtualHosts != [ ]) {
    # 1: any cookie whose name starts with oauth2-proxy's (the session, its
    # _0/_1 splits, the CSRF cookies), then the same name again after a ';'.
    # 2, 3: the whole session name together with one of its split pieces,
    # in either order.
    services.nginx.appendHttpConfig =
      let
        n = lib.escapeRegex name;
      in
      ''
        map $http_cookie $oauth2_proxy_cookie_twice {
          default 0;
          "~(?:^|;)\s*(${n}[A-Za-z0-9_-]*)=[^;]*;(?:.*;)?\s*\1=" 1;
          "~(?:^|;)\s*${n}=[^;]*;(?:.*;)?\s*${n}_[0-9]+=" 1;
          "~(?:^|;)\s*${n}_[0-9]+=[^;]*;(?:.*;)?\s*${n}=" 1;
        }
      '';
    services.nginx.virtualHosts = lib.genAttrs cfg.virtualHosts (_: {
      extraConfig = ''
        if ($oauth2_proxy_cookie_twice) {
          return 400 "A login cookie of this site arrived twice (one was set by another site). Clear this site's cookies and sign in again.\n";
        }
      '';
    });
  };
}
