/*
  The spaces' published web apps, the host's front (som: on top of
  hyperhermes' exposure, sso and publish modules, whose login it shares).
  Imported by machines that run both spaces and hyperhermes' publish; the
  port window, the output gate and the guest's side come with ./default.nix
  and ./publish-guest.nix wherever a space runs.

  https://<port>.<space>.<domain>/, for every port of the space's window
  (hyper.spaces.<name>.publish.from .. to, 8000-8099), is one nginx vhost
  per space that dials http://<guest's veth address>:<port>. Exactly the
  serve ports' private kind (hyperhermes/modules/publish, whose header
  says why each piece is there), on a host family of its own:

    - login: hyperhermes' `oauth2-proxy-serve` on its root-held socket,
      the same OIDC client `hermes-serve`, its endpoints below
      /.hermes-serve-login/ on the port's own host, a host-only
      __Host-hermes_serve cookie per port host. The inventory
      (modules/flake-parts/nixosConfigurations.nix) adds the callback
      pattern https://*.<space>.<domain>/.hermes-serve-login/callback to
      that client and the group space-<space> to its allowed groups,
      which ./registry.nix's `owners` join.
    - authorization: a map over "<host> <account>" (the ID token's
      preferred_username) names the backend; the space's owners (the
      `publish.accounts` option, ./registry.nix's `owners`) get the guest,
      every other account the publish module's 403 server.
    - what reaches the app: hyperhermes' allowlist of cookies (no login
      cookie ever reaches the space), Host 127.0.0.1:<port>, a same-origin
      Origin rewritten to http://127.0.0.1:<port>, X-Forwarded-*, Set-
      Cookie domains pinned to the port's host, websockets; the Fetch
      Metadata gate (exposure) and the agents' request limits.
    - the backend is the guest itself: nginx's uid may open connections
      into the space's veth on the window only (./host.nix's output gate,
      `toGuestRules` from ./default.nix), the guest admits only the
      host's veth address (./guest-base.nix). Only the space binds there,
      so no squatter question as with the agents' loopback ports. An app
      that is down gives 502.
    - TLS and DNS: one wildcard certificate *.<space>.<domain> by
      exposure's DNS-01 (space-publish-<space>), the wildcard record
      *.<space>.<domain> with exposure's A/AAAA, no TXT (exposure's
      header). No port number lands in the CT logs.

  A space name must be no agent's (both own *.<name>.<domain>): asserted.
*/
{
  config,
  lib,
  inputs,
  ...
}:
let
  registry = import ./registry.nix;
  inherit (config.services.hyperhermes) exposure;
  ssoLib = inputs.hyperhermes.lib.sso;
  loginPrefix = ssoLib.publishLoginPrefix;
  # hyperhermes' publish module's sockets (its header): the private
  # ports' oauth2-proxy and nginx's 403 server.
  login = "unix:/run/oauth2-proxy-serve.sock:";
  forbidden = "unix:/run/nginx/hermes-serve-forbidden.sock";

  spaces = lib.filterAttrs (
    name: _: config.hyper.spaces.${name}.enable && config.hyper.spaces.${name}.publish.enable
  ) registry;
  pcfg = name: config.hyper.spaces.${name}.publish;
  hostsOf = name: map (port: "${toString port}.${name}.${exposure.domain}") (lib.range (pcfg name).from (pcfg name).to);
  certOf = name: "space-publish-${name}";
  vhostOf = name: "space-publish-${name}";
  guestOf = name: config.containers.${name}.localAddress;

  loginHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $host;
  '';
in
{
  config = lib.mkIf (spaces != { }) {
    assertions = [
      {
        assertion = config.services.hyperhermes.publish.enable && exposure.mode == "public";
        message = "spaces/publish.nix needs hyperhermes' publish module (its login) in public exposure mode.";
      }
    ]
    ++ lib.mapAttrsToList (name: _: {
      assertion = !(config.services.hyperhermes.agents ? ${name});
      message = "hyper.spaces.${name}: an agent of the same name owns *.${name}.${exposure.domain}.";
    }) spaces
    ++ lib.mapAttrsToList (name: _: {
      assertion = (pcfg name).domain == exposure.domain;
      message = "hyper.spaces.${name}.publish.domain must be the agents' exposure domain ${exposure.domain} (the shared login's cookies and callbacks live there).";
    }) spaces;

    services.nginx.appendHttpConfig = ''
      map "$host $hermes_serve_account" $space_publish_backend {
        default ${forbidden};
      ${lib.concatStrings (
        lib.mapAttrsToList (
          name: _:
          lib.concatMapStrings (
            account:
            "  \"~^[0-9]+\\.${lib.escapeRegex "${name}.${exposure.domain}"} ${lib.escapeRegex account}$\" ${guestOf name}:$hermes_serve_port;\n"
          ) (pcfg name).accounts
        ) spaces
      )}}
    '';

    services.nginx.virtualHosts = lib.mapAttrs' (
      name: _:
      let
        hosts = hostsOf name;
      in
      lib.nameValuePair (vhostOf name) (
        exposure.virtualHost (certOf name)
        // {
          serverName = lib.head hosts;
          serverAliases = lib.tail hosts;
          extraConfig = ''
            limit_req zone=hermes_agent_requests burst=500 nodelay;
            limit_conn hermes_agent_conns 128;
            limit_conn hermes_agent_host_conns 384;
            limit_req_status 429;
            limit_conn_status 429;
          '';
          locations."${loginPrefix}/" = {
            proxyPass = "http://${login}";
            recommendedProxySettings = false;
            extraConfig = loginHeaders;
          };
          locations."= /.hermes-serve-auth".extraConfig = ''
            internal;
            proxy_pass http://${login}${loginPrefix}/auth;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            ${loginHeaders}
          '';
          locations."= /.hermes-serve-start".extraConfig = ''
            internal;
            proxy_pass http://${login}${loginPrefix}/start;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header X-Auth-Request-Redirect $request_uri;
            ${loginHeaders}
          '';
          locations."/" = {
            proxyPass = "http://$space_publish_backend";
            proxyWebsockets = true;
            recommendedProxySettings = false;
            extraConfig = ''
              auth_request /.hermes-serve-auth;
              auth_request_set $hermes_serve_account $upstream_http_x_auth_request_preferred_username;
              error_page 401 = /.hermes-serve-start;
              proxy_set_header Host 127.0.0.1:$hermes_serve_port;
              proxy_set_header Origin $hermes_serve_origin;
              proxy_set_header Cookie $hermes_serve_cookie;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Forwarded-Host $host;
              proxy_cookie_domain ~.+ $host;
              proxy_read_timeout 1h;
              proxy_send_timeout 1h;
              client_max_body_size 256m;
            '';
          };
        }
      )
    ) spaces;

    services.hyperhermes.exposure.fetchMetadataGate.virtualHosts = map vhostOf (lib.attrNames spaces);
    services.hyperhermes.exposure.records = lib.mkIf (exposure.hostRecords != { }) (
      lib.mapAttrs' (
        name: _: lib.nameValuePair "*.${name}.${exposure.domain}" (removeAttrs exposure.hostRecords [ "TXT" ])
      ) spaces
    );
    security.acme.certs = lib.mapAttrs' (
      name: _: lib.nameValuePair (certOf name) (exposure.acmeCert "*.${name}.${exposure.domain}")
    ) spaces;
  };
}
