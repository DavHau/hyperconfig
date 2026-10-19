# Refuse (403) what a browser marks as sent from another origin, unless it
# is a plain top-level navigation (Fetch Metadata, the Sec-Fetch-* request
# headers).
#
# Why: on som every agent's pages share one site, davhau.fyi
# (./hermes-dashboard-public.nix), until that domain is on the Public
# Suffix List. To the browser, agent A's page is then same-site with agent
# B's dashboard and private serve ports, so B's SameSite=Lax login cookies
# ride along on every form post, fetch or websocket A's page starts there.
# Host-only cookies and per-agent OIDC clients stop A from reading or
# setting B's logins, not from using them through the visitor's browser
# (CSRF). This gate does, on the vhosts it is applied to.
#
# Allowed:
#   - no Sec-Fetch-Site at all: not a browser (curl, the Hermes Mobile
#     app's OkHttp client), or one too old to send it,
#   - Sec-Fetch-Site same-origin or none (typed URL, bookmark, a link opened
#     from another app, a Custom Tab),
#   - same-site and cross-site only as a top-level navigation without side
#     effects: Sec-Fetch-Mode navigate, method GET or HEAD, Sec-Fetch-Dest
#     document (or absent). Links and redirects keep working, the OIDC
#     callbacks among them (the issuer at id.davhau.com redirects there
#     cross-site, by GET).
# Refused: everything else from another origin, i.e. form posts, fetch and
# XHR, websockets, iframes, images, scripts.
#
# Residual: a cross-origin GET navigation passes, so an app with side
# effects on GET stays exposed to links; browsers without Fetch Metadata
# (Safari before 16.4) are not protected.
#
# What it breaks (no security impact): a cross-site top-level POST is
# refused, so an OIDC provider answering with response_mode=form_post
# would fail at the callback (hermes and oauth2-proxy use the query mode,
# pocket-id redirects by GET), and so would an app's own cross-site form
# posts to these hosts. A client still posting to an old name (a stale
# Hermes Mobile server address) loses the body anyway: the 301 to the new
# name turns the POST into a GET.
{ config, lib, ... }:
let
  cfg = config.hyper.fetchMetadataGate;
in
{
  options.hyper.fetchMetadataGate.virtualHosts = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "nginx virtualHosts (attribute names) that answer 403 to browser requests from another origin, top-level GET navigations excepted.";
  };

  config = lib.mkIf (cfg.virtualHosts != [ ]) {
    # site:mode:method:dest. 1: no site, same-origin or none. 2: a top-level
    # navigation by GET or HEAD.
    services.nginx.appendHttpConfig = ''
      map "$http_sec_fetch_site:$http_sec_fetch_mode:$request_method:$http_sec_fetch_dest" $fetch_metadata_refused {
        default 1;
        "~^(same-origin|none)?:" 0;
        "~^[^:]*:navigate:(GET|HEAD):(document)?$" 0;
      }
    '';
    services.nginx.virtualHosts = lib.genAttrs cfg.virtualHosts (_: {
      extraConfig = ''
        if ($fetch_metadata_refused) {
          return 403 "Refused: a request from another site.\n";
        }
      '';
    });
  };
}
