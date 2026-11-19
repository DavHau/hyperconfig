# The agents' opt-in residential proxy (browser.residentialProxy.url): an
# authenticated forward proxy on this host that exits through home
# connections (hyperconfig: modules/nixos/residential-proxy, Evomi), for
# sites that block the host's own egress. Off unless the host sets the URL.
#
# Opt-in per request, never the default:
#   - web_extract_residential (the web-local-extract plugin's second tool,
#     ./web-extract): the same fetch and browser retry as web_extract, its
#     traffic through the proxy, with a `country`;
#   - browser_residential (the camofox plugin's extra tool,
#     ../../pkgs/hermes-camofox-plugin): turns the agent's Camofox session
#     onto the proxy (and `off` back), a separate browser context per
#     chosen country; the server's residential plugin
#     (../../pkgs/camofox-browser/residential-plugin);
#   - the `residential-proxy` skill (./residential-proxy-skill): when to use
#     it (only after a block; never for logins to the owner's accounts
#     unless asked), costs, countries, the error when the traffic is gone;
#   - RESIDENTIAL_PROXY_URL in the agent's .env, for the terminal (curl -x).
# SearXNG's engines that the host's egress cannot reach go through it by
# default (browser.residentialProxy.searxngEngines, ./searxng.nix).
#
# The URL carries no secret: the proxy holds the provider's credentials
# and decides who may connect (the host's job; hyperconfig gates the port
# by uid). The country rides the proxy username (`sg`, `us-session-<id>`).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hyperhermes;
  rp = cfg.browser.residentialProxy;
  skill = import ../../lib/agent-skill.nix pkgs {
    name = "residential-proxy";
    src = lib.fileset.toSource {
      root = ./residential-proxy-skill;
      fileset = ./residential-proxy-skill/SKILL.md;
    };
  };
in
{
  options.services.hyperhermes.browser.residentialProxy = with lib; {
    url = mkOption {
      type = types.nullOr (types.strMatching "http://127\\.0\\.0\\.1:[0-9]+");
      default = null;
      example = "http://127.0.0.1:8897";
      description = ''
        The host's residential forward proxy (HTTP, CONNECT), on loopback.
        Null: none of the residential tools, skill or variables exist.
      '';
    };
    defaultCountry = mkOption {
      type = types.strMatching "[A-Z]{2}";
      default = "SG";
      description = "The proxy's default exit country, for the skill's text.";
    };
    searxngEngines = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "google"
        "qwant"
      ];
      description = ''
        SearXNG engines that always go through the proxy (and are switched
        on): those that block the host's own egress outright.
      '';
    };
  };

  options.services.hyperhermes.agents = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          config = lib.mkIf (cfg.browser.enable && config.browser.enable && rp.url != null) {
            environment.RESIDENTIAL_PROXY_URL = lib.mkDefault rp.url;
            skillDirs = [ "${skill}/share/skills" ];
          };
        }
      )
    );
  };
}
