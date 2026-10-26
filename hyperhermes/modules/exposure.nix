# How the agents' web surfaces are reached: one nginx that routes by Host
# under a base domain. Every feature that publishes something (dashboards,
# the identity provider, serve ports) adds a virtual host on `nginxListen`
# and builds its URLs with `urlOf`, so the same routing works in every mode.
#
# Local mode serves plain HTTP on a loopback port under a *.localhost
# domain: browsers resolve every *.localhost name to loopback by themselves
# and treat it as a secure context, and glibc does the same through
# nss-myhostname (on by default in NixOS), so the same URLs work for a
# browser on the host and for processes on this machine. Run in a NixOS
# container with a private network, the container listens on its own
# address too and the host forwards its loopback port there
# (checks/local-sso shows the setup).
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hyperhermes.exposure;
in
{
  options.services.hyperhermes.exposure = {
    enable = lib.mkEnableOption "the nginx front for the agents' web surfaces";

    mode = lib.mkOption {
      type = lib.types.enum [ "local" ];
      default = "local";
      description = "`local`: plain HTTP on `port`, reachable from this machine (or its container host) only.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "hermes.localhost";
      description = "Base domain; every published name sits below it.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8473;
      description = "Port nginx serves on, part of every URL in local mode.";
    };

    listenAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "127.0.0.1"
        "[::1]"
      ];
      description = ''
        Addresses nginx listens on. nss-myhostname answers *.localhost with
        both ::1 and 127.0.0.1, so loopback means both families. A container
        adds its private address for the host's forward.
      '';
    };

    nginxListen = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      description = "`listen` of every virtual host a feature publishes.";
    };

    urlOf = lib.mkOption {
      type = lib.types.functionTo lib.types.str;
      readOnly = true;
      description = "Origin (scheme, host, port) of a published host name.";
    };
  };

  config = lib.mkMerge [
    {
      services.hyperhermes.exposure = {
        nginxListen = map (addr: {
          inherit addr;
          inherit (cfg) port;
        }) cfg.listenAddresses;
        urlOf = (import ../lib/url.nix { inherit lib; }).originOf {
          scheme = "http";
          inherit (cfg) port;
        };
      };
    }

    (lib.mkIf cfg.enable {
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        # Names nothing publishes get no answer rather than some feature's
        # page.
        virtualHosts.hermes-default = {
          default = true;
          serverName = "_";
          listen = cfg.nginxListen;
          locations."/".return = "404";
        };
      };
    })
  ];
}
