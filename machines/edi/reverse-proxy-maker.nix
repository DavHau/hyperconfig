# Secret HTTP endpoint whose hostname never enters the world-readable nix store.
#
# The bare subdomain label (e.g. <label>) is prompted at
# `clan vars generate` time, encrypted via sops, and materialised at runtime to
# /run/secrets/vars/maker-1/servername as the literal nginx directive
#   server_name <fqdn>;
# nginx `include`s that file at startup, so the name only ever lives in the
# decrypted runtime secret -- not in nix code, the store, or git.
#
# The proxy upstream (e.g. http://localhost:8787) is a second secret var in the
# same generator: prompt `upstream` -> file `proxypass` holding
# `proxy_pass <url>;`, `include`d inside `location /`. Both vars stay out of the
# store/git. Add maker-2, maker-3, ... generators for further subdomains.
#
# We therefore CANNOT use services.nginx.virtualHosts.<name>: the module writes
# `server_name ${name}` verbatim into nginx.conf at eval time (world-readable
# store). The server block is hand-written via appendHttpConfig instead.
#
# TLS uses a wildcard cert for *.maker.davhau.com via the porkbun DNS-01
# challenge, reusing the porkbun API credentials already managed by
# modules/nixos/dyndns-porkbun.nix. A wildcard keeps the secret label out of
# public Certificate Transparency logs (a per-host cert would publish it).
{ config, ... }:
let
  cert = config.security.acme.certs."maker.davhau.com";
  servername = config.clan.core.vars.generators.maker-1.files.servername.path;
  proxypass = config.clan.core.vars.generators.maker-1.files.proxypass.path;
in
{
  # --- secret hostname + upstream, derived from prompts into nginx snippets -
  clan.core.vars.generators.maker-1 = {
    files.servername = {
      secret = true;
      owner = "nginx";
    };
    files.proxypass = {
      secret = true;
      owner = "nginx";
    };
    prompts.subdomain = {
      description = "Subdomain label under maker.davhau.com (e.g. <label> -> <label>.maker.davhau.com)";
      type = "line";
    };
    prompts.upstream = {
      description = "Backend the endpoint proxies to (e.g. http://localhost:8787)";
      type = "line";
    };
    script = ''
      printf 'server_name %s.maker.davhau.com;\n' "$(cat "$prompts"/subdomain)" > "$out"/servername
      printf 'proxy_pass %s;\n'  "$(cat "$prompts"/upstream)" > "$out"/proxypass
    '';
  };

  # --- wildcard TLS via porkbun DNS-01 -------------------------------------
  # ACME cert attr name must not contain '*'; the wildcard goes in `domain`.
  security.acme.certs."maker.davhau.com" = {
    domain = "*.maker.davhau.com";
    dnsProvider = "porkbun";
    # nginx runs as the `nginx` group; acme certs default to group `acme`, which
    # nginx can't read. The nginx module sets group=nginx for certs bound to its
    # own vhosts -- ours isn't, so set it explicitly or nginx fails with
    # `cannot load certificate ... BIO_new_file() failed`.
    group = "nginx";
    # lego reads any var's _FILE twin; the acme module passes these via systemd
    # LoadCredential (read as root, so root-owned clan secrets are fine).
    credentialFiles = {
      "PORKBUN_API_KEY_FILE" = config.clan.core.vars.generators.porkbun.files.apikey.path;
      "PORKBUN_SECRET_API_KEY_FILE" = config.clan.core.vars.generators.porkbun.files.secretkey.path;
    };
    # Reload nginx once the real cert replaces the boot-time self-signed one.
    reloadServices = [ "nginx.service" ];
  };

  # --- nginx: hand-written server block ------------------------------------
  services.nginx.enable = true;
  services.nginx.appendHttpConfig = ''
    server {
      listen 443 ssl;
      listen [::]:443 ssl;
      http2 on;

      # secret server_name, injected at runtime from the sops-decrypted file
      include ${servername};

      ssl_certificate     ${cert.directory}/fullchain.pem;
      ssl_certificate_key ${cert.directory}/key.pem;

      # reverse proxy to the secret upstream, injected at runtime from sops
      location / {
        include ${proxypass};

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_pass_header Authorization;

        # websocket support (matches the other edi vhosts)
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
      }
    }
  '';

  # The nginx module only wires acme ordering for certs referenced by its own
  # virtualHosts. This cert isn't, so replicate the ordering by hand: start
  # after the baseline (self-signed) cert exists, before the DNS-01 issuance.
  systemd.services.nginx = {
    wants = [ "acme-maker.davhau.com.service" ];
    after = [ "acme-maker.davhau.com.service" ];
    before = [ "acme-order-renew-maker.davhau.com.service" ];
  };
}
