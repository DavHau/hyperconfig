# Residential proxy for som's hermes agents: Evomi's Core Residential
# pool (pay-as-you-go traffic, bought 2026-11 with BTC), behind a loopback
# gateway on som (./service.nix, ./gateway.py) that holds the account's
# proxy credentials, so no agent ever sees them.
#
#   - who: every hyperhermes agent on som (their uids), opt-in per request
#     (hyperhermes' browser.residentialProxy: web_extract_residential,
#     browser_residential, RESIDENTIAL_PROXY_URL, the residential-proxy
#     skill), and searx for Google and Qwant (which block som's Mullvad
#     exit; on by default through the proxy). Nothing else uses it.
#   - egress: the gateway's uid is Mullvad-tunneled (hyper.mullvadEgress)
#     and tunnelOnly (only its own listener and the tunnel's DNS on
#     loopback), so Evomi sees a Mullvad address, never som's.
#   - exit country: SG by default, per request by the client's proxy
#     username (`us`, `de-session-<id>`).
#   - no quotas or caps: when the traffic is used up, Evomi refuses and
#     the gateway answers 402 with a reason the tools pass on.
#
# Vars (shared, so any machine's clan can read them; deployed on som only):
#   evomi-account/{email (public), password}: the dashboard login
#     (my.evomi.com), generated once; never deployed.
#   evomi-proxy/{user, password}: the proxy credentials from Evomi's
#     dashboard (Proxy Generator), set by hand with `clan vars set` (no
#     prompt: never asked at deploy); endpoint (public): the TLS proxy
#     endpoint they belong to.
# Top up: log in at my.evomi.com with evomi-account, Core Residential ->
# Pay As You Go -> crypto (Cryptomus, on-chain BTC; no Lightning).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vars = config.clan.core.vars.generators;
  endpoint = builtins.fromJSON vars.evomi-proxy.files.endpoint.value;
  rp = config.hyper.residentialProxy;
in
{
  imports = [ ./service.nix ];

  clan.core.vars.generators.evomi-account = {
    share = true;
    files.email = {
      secret = false;
      deploy = false;
    };
    files.password.deploy = false;
    runtimeInputs = [ pkgs.pwgen ];
    script = ''
      printf %s infra@agents.davhau.com > "$out/email"
      pwgen -s -y -r "\"'\`\\" 32 1 | tr -d '\n' > "$out/password"
    '';
  };

  # Values from Evomi's dashboard, stored with `clan vars set`; the
  # script only fails, so a missing value is an error, never a prompt.
  clan.core.vars.generators.evomi-proxy = {
    share = true;
    files.user = { };
    files.password = { };
    files.endpoint.secret = false;
    script = ''
      echo "evomi-proxy: set by hand from Evomi's dashboard (clan vars set <m> evomi-proxy/<file>)" >&2
      exit 1
    '';
  };

  hyper.residentialProxy = {
    enable = true;
    uid = 1222; # ../vault-ids.nix ladder
    defaultCountry = "SG";
    upstream = {
      inherit (endpoint) host port;
    };
    userFile = vars.evomi-proxy.files.user.path;
    passwordFile = vars.evomi-proxy.files.password.path;
    clients = [ "searx" ] ++ lib.attrNames config.services.hyperhermes.agents;
  };

  # Only through Mullvad, and on loopback only its own listener and the
  # tunnel's DNS.
  hyper.mullvadEgress = {
    users = [ rp.user ];
    dns.services = [ "residential-proxy" ];
    tunnelOnly.residential-proxy = [ "127.0.0.1:${toString rp.port}" ];
  };

  # The agents' tools, SearXNG's Google and Qwant.
  services.hyperhermes.browser.residentialProxy = {
    inherit (rp) url defaultCountry;
    searxngEngines = [
      "google"
      "qwant"
    ];
  };
  # searx's tunnelOnly (../../../machines/som/hermes-agents.nix) admits
  # only its own listener on loopback: the gateway too.
  hyper.mullvadEgress.tunnelOnly.searx = [ "127.0.0.1:${toString rp.port}" ];
}
