# Web pages the native hermes agents serve, published under the dashboard
# host: https://<port>.<dashboard host>/ -> nginx -> 127.0.0.1:<port>.
#
# Ports: each agent owns 10 loopback ports, servePortBase + (uid - 1000) * 10
# .. +9, disjoint per uid and below the kernel's ephemeral range (32768+).
# The first five are PRIVATE: pocket-id login through the dashboard's
# oauth2-proxy, and only the agent's own dashboard account
# (hyper.hermesDashboard.users.<name>.account) gets through. The last five
# are PUBLIC: no login. The agent picks the mode by picking the port; the
# URL cannot upgrade a private port to public.
#
# One wildcard vhost serves both modes. nginx cannot switch auth_request on
# and off per variable, so the auth subrequest answers 204 itself for a
# public port and asks oauth2-proxy otherwise. The backend comes from a map
# over "<port> <account>": public ports match any account, private ports
# only their owner; everything else lands on a 403 listener. The map runs
# at proxy_pass time, after auth_request_set, which an `if` would not.
#
# Agents are untrusted, so nothing of the visitor's login reaches them:
#   - oauth2-proxy's cookie is scoped to .<host> (it must cover the
#     subdomains) and nginx strips every _oauth2_proxy* cookie before
#     proxying,
#   - proxy_cookie_domain pins any Set-Cookie Domain to the serving
#     subdomain, so an agent cannot plant cookies on the dashboard host
#     through headers (document.cookie still can; residual),
#   - the ports are owner-only on loopback (iptables, same chain spaces
#     uses for the dashboard ports): the owner, nginx and root may dial
#     them, other agents may not. Nothing opens them in the firewall.
#
# TLS: one wildcard cert via porkbun DNS-01 (as edi's *.maker.davhau.com).
# DNS: `porkbun-dns set '*.<host>' AAAA <public v6>` (tools/porkbun-dns),
# the same address as <host>.
#
# The serve-ports skill (./hermes-agents-serve-skill, rendered with this
# host's port table) teaches the agent all of this.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  agents = config.hyper.hermesAgents;
  dashboard = config.hyper.hermesDashboard;
  host = dashboard.host;
  certName = "hermes-serve";

  servePortBase = 30000;
  portsOf =
    name:
    let
      from = servePortBase + (config.users.users.${name}.uid - 1000) * 10;
    in
    {
      inherit from;
      private = lib.genList (i: from + i) 5;
      public = lib.genList (i: from + 5 + i) 5;
      to = from + 9;
    };
  accountOf = name: dashboard.users.${name}.account;

  # Nothing of the agents listens here; nginx answers 403 from its own
  # server block (hermes-dashboard-public.nix owns 20000 - 1).
  forbiddenPort = servePortBase - 1;
  oauth2 = config.services.oauth2-proxy.httpAddress;

  range = p: "${toString p.from}-${toString p.to}";
  portList = ps: lib.concatMapStringsSep ", " toString ps;
  skill = inputs.spaces.lib.mkAgentSkill pkgs {
    name = "serve-ports";
    src = pkgs.writeTextDir "SKILL.md" (
      builtins.replaceStrings
        [ "@HOST@" "@PORTS@" ]
        [
          host
          (lib.concatMapStringsSep "\n" (
            name:
            let
              p = portsOf name;
            in
            "| ${name} | ${portList p.private} | ${portList p.public} |"
          ) (lib.attrNames agents))
        ]
        (builtins.readFile ./hermes-agents-serve-skill/SKILL.md)
    );
  };

  # Drops one `_oauth2_proxy*=...` pair per map; three in a row cover the
  # session cookie, a split second chunk and a CSRF cookie.
  stripCookie = from: to: n: ''
    map ${from} ${to} {
      default ${from};
      "~^(?<hs_pre${n}>.*?)_oauth2_proxy[^=;]*=[^;]*;?\s*(?<hs_post${n}>.*)$" "$hs_pre${n}$hs_post${n}";
    }
  '';
in
{
  config = lib.mkIf (agents != { }) {
    assertions = lib.mapAttrsToList (name: _: {
      assertion =
        let
          uid = config.users.users.${name}.uid;
        in
        uid == null || (uid >= 1000 && (portsOf name).to < 32768);
      message = "hyper.hermesAgents.${name}: uid must be in 1000..1276 so its serve ports (${toString servePortBase} + (uid - 1000) * 10) stay below the ephemeral range.";
    }) agents;

    services.hermes-microvm.settings.skills.external_dirs = [ "${skill}/share/skills" ];

    # Loopback owner gate, after spaces' rules (they never name these ports).
    systemd.services.hermes-firewall.script = lib.mkAfter (
      lib.concatMapStrings (
        name:
        let
          ports = "${toString (portsOf name).from}:${toString (portsOf name).to}";
        in
        ''
          iptables -w -A hermes-microvm -p tcp --dport ${ports} -m owner --uid-owner ${name} -j RETURN
          iptables -w -A hermes-microvm -p tcp --dport ${ports} -m owner --uid-owner nginx -j RETURN
          iptables -w -A hermes-microvm -p tcp --dport ${ports} -m owner --uid-owner 0 -j RETURN
          iptables -w -A hermes-microvm -p tcp --dport ${ports} -j REJECT --reject-with tcp-reset
        ''
      ) (lib.attrNames agents)
    );

    # The login cookie has to reach <port>.<host>; the post-login redirect
    # back there has to be allowed. No leading dot on the cookie domain:
    # oauth2-proxy picks it by suffix match against the request host, which
    # must also hold for <host> itself; browsers send a Domain cookie to
    # every subdomain anyway.
    services.oauth2-proxy = {
      cookie.domain = host;
      extraConfig.whitelist-domain = ".${host}";
    };

    # Shared var, same definition as ./dyndns-porkbun.nix; only DNS-01
    # reads it here.
    clan.core.vars.generators.porkbun = {
      share = true;
      prompts.apikey.type = "hidden";
      prompts.apikey.persist = true;
      prompts.secretkey.type = "hidden";
      prompts.secretkey.persist = true;
    };
    security.acme.certs.${certName} = {
      domain = "*.${host}";
      dnsProvider = "porkbun";
      # Not an enableACME cert, so the nginx module leaves the group alone.
      group = "nginx";
      credentialFiles = {
        PORKBUN_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.apikey.path;
        PORKBUN_SECRET_API_KEY_FILE = config.clan.core.vars.generators.porkbun.files.secretkey.path;
      };
    };

    services.nginx = {
      appendHttpConfig = ''
        map $hermes_serve_port $hermes_serve_public {
          default 0;
        ${lib.concatMapStrings (name: lib.concatMapStrings (p: "  ${toString p} 1;\n") (portsOf name).public) (
          lib.attrNames agents
        )}}

        map "$hermes_serve_port $hermes_serve_account" $hermes_serve_backend {
          default 127.0.0.1:${toString forbiddenPort};
        ${lib.concatMapStrings (
          name:
          let
            p = portsOf name;
          in
          lib.concatMapStrings (port: "  \"~^${toString port} \" 127.0.0.1:${toString port};\n") p.public
          + lib.concatMapStrings (port: "  \"${toString port} ${accountOf name}\" 127.0.0.1:${toString port};\n") p.private
        ) (lib.attrNames agents)}}

        ${stripCookie "$http_cookie" "$hermes_serve_cookie1" "1"}
        ${stripCookie "$hermes_serve_cookie1" "$hermes_serve_cookie2" "2"}
        ${stripCookie "$hermes_serve_cookie2" "$hermes_serve_cookie" "3"}
      '';

      virtualHosts = {
        ${certName} = {
          serverName = "~^(?<hermes_serve_port>[0-9]+)\\.${lib.escapeRegex host}$";
          forceSSL = true;
          useACMEHost = certName;
          locations."= /.hermes-serve-auth".extraConfig = ''
            internal;
            if ($hermes_serve_public) {
              return 204;
            }
            proxy_pass ${oauth2}/oauth2/auth;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
            proxy_set_header Host $host;
            proxy_set_header X-Scheme $scheme;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          '';
          locations."@hermes-serve-login".return = "307 https://${host}/oauth2/start?rd=$scheme://$host$request_uri";
          locations."/" = {
            proxyPass = "http://$hermes_serve_backend";
            proxyWebsockets = true;
            # Loopback Host: dev servers (vite, jupyter) reject unknown
            # hosts; the public one rides in X-Forwarded-Host.
            recommendedProxySettings = false;
            extraConfig = ''
              auth_request /.hermes-serve-auth;
              auth_request_set $hermes_serve_account $upstream_http_x_auth_request_preferred_username;
              error_page 401 = @hermes-serve-login;
              proxy_set_header Host 127.0.0.1:$hermes_serve_port;
              proxy_set_header Origin "";
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
        };
        hermes-serve-forbidden = {
          serverName = "_";
          listen = [
            {
              addr = "127.0.0.1";
              port = forbiddenPort;
            }
          ];
          locations."/".return = "403 'Not published, or not published for this account.\\n'";
          extraConfig = "default_type text/plain;";
        };
      };
    };
  };
}
